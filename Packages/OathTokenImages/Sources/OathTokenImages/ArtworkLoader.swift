import OathDiagnostics
import Foundation
import OathArtworkSource

public protocol ArtworkTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

/// A verified directory-shaped optional logo returned 404/410, not a failed
/// image decoder or provider outage. No URL or response body is retained.
struct OptionalArtworkAbsent: Error, Sendable {}

/// Retains only a bounded retry interval, never response headers or URLs.
public struct ArtworkRateLimit: Error, CustomNSError, Sendable {
    public let delay: TimeInterval
    public static var errorDomain: String { "OathTokenImages.ArtworkRateLimit" }
    public var errorCode: Int { 429 }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: "Artwork provider rate limited"] }

    public init(retryAfter: String?, now: Date = .now) {
        var interval = retryAfter.flatMap(Double.init)
        if interval == nil, let retryAfter, retryAfter.utf8.count <= 128 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            interval = formatter.date(from: retryAfter)?.timeIntervalSince(now)
        }
        delay = interval.map { $0.isFinite ? min(3600, max(60, $0)) : 60 } ?? 60
    }
}

/// No app credentials, cookies, or wallet identifiers accompany image requests.
public final class ArtworkURLTransport: NSObject, ArtworkTransport, URLSessionTaskDelegate, Sendable {
    public override init() { super.init() }
    public func data(from url: URL) async throws -> Data {
        guard ArtworkSource.permits(url) else { throw ArtworkError.invalidSource }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(url.host == "tokens.coingecko.com" ? "application/json" :
            "image/avif,image/webp,image/png,image/jpeg,image/svg+xml,image/*;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArtworkError.invalidImage }
        try Self.validate(http, request: request)
        guard let finalURL = response.url, ArtworkSource.permits(finalURL) else { throw ArtworkError.invalidSource }
        guard response.expectedContentLength <= ArtworkSource.byteLimit else { throw ArtworkError.oversized }
        var result = Data()
        for try await byte in bytes {
            guard result.count < ArtworkSource.byteLimit else { throw ArtworkError.oversized }
            result.append(byte)
        }
        return result
    }
    static func validate(_ response: HTTPURLResponse, request: URLRequest) throws {
        // diagnostics: optional-artwork-absence. Trust Wallet's contract paths
        // are guesses; many valid tokens have no listing/image. Only the exact
        // recognized path's own 404/410 is absence. Redirect failures, arbitrary
        // image URLs, catalog errors, permissions and server failures still log.
        if [404, 410].contains(response.statusCode), response.url == request.url,
           let source = request.url?.absoluteString, ArtworkFallbackCatalog.identity(source) != nil {
            throw OptionalArtworkAbsent()
        }
        DiagnosticHTTP.response(Data(), status: response.statusCode, request: request)
        if response.statusCode == 429 {
            throw ArtworkRateLimit(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
        guard response.statusCode == 200 else { throw ArtworkError.http(response.statusCode) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(ArtworkSource.permits) == true ? request : nil)
    }
}

/// One pipeline for lists, search, activity, details, and exports. Deduplication
/// uses the complete artwork URI, so identical tickers cannot share wrong icons.
public actor ArtworkLoader {
    public static let shared = ArtworkLoader()
    private struct Entry { let image: ArtworkImage; let fetched: Date }
    private struct DiskEntry: Codable { let data: Data; let fetched: Date }
    private struct Absence: Codable { let checked: Date }
    private final class Box: NSObject {
        let entry: Entry
        init(_ entry: Entry) { self.entry = entry }
    }
    private let memory = NSCache<NSString, Box>()
    private let directory: URL
    private let transport: any ArtworkTransport
    private let fallbackCatalog: ArtworkFallbackCatalog
    private let freshFor: TimeInterval
    private let retryAfter: TimeInterval
    private let now: @Sendable () -> Date
    private let work = ArtworkWorkPool<String, ArtworkImage>(concurrency: 12)
    private let downloads = ArtworkWorkPool<String, Result<Data, Error>>(concurrency: 6)
    private let diskIndex: ArtworkDiskIndex
    private var failures: [String: Date] = [:]

    public init(directory: URL? = nil, transport: any ArtworkTransport = ArtworkURLTransport(),
                freshFor: TimeInterval = 7 * 24 * 3600, retryAfter: TimeInterval = 30,
                diskLimit: Int = 128 * 1024 * 1024,
                fallbackCatalog: ArtworkFallbackCatalog = .shared,
                now: @escaping @Sendable () -> Date = { .now }) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OathTokenArtwork-v1", isDirectory: true)
        self.diskIndex = ArtworkDiskIndex(directory: self.directory, extensions: ["artwork", "missing"],
            byteLimit: diskLimit, countLimits: ["missing": 256])
        self.transport = transport
        self.fallbackCatalog = fallbackCatalog
        self.freshFor = freshFor
        self.retryAfter = retryAfter
        self.now = now
        memory.totalCostLimit = 48 * 1024 * 1024
        memory.countLimit = 128
    }

    /// Show saved artwork immediately, including offline/expired originals.
    public func cached(for sources: [String], maxPixelSize: Int? = nil) -> ArtworkImage? {
        for source in ArtworkSource.candidates(sources) {
            if let entry = stored(source, maxPixelSize: maxPixelSize) { return entry.image }
        }
        return nil
    }

    /// A directory-shaped URL is only a guess, not proof the image exists.
    /// Prefer the published list's exact chain/contract match before requesting
    /// that URL or one metadata response per search result. The catalog already
    /// coalesces requests and applies provider-wide retry limits.
    func catalogSources(for token: TokenArtworkIdentity, sources: [String]) async -> [String] {
        for source in ArtworkSource.candidates(sources) {
            guard let identity = ArtworkFallbackCatalog.identity(source),
                  identity.networkID == token.networkID, identity.contract == token.reference else { continue }
            let published = await fallbackCatalog.sources(for: source)
            if !published.isEmpty { return published }
        }
        // Unsupported/absent optional listings are not app failures. Actual
        // transport/decoding failures are reported by the shared catalog.
        return []
    }

    /// Resolve a known token's current published artwork without guessing a URL
    /// or matching its symbol. The catalog retains its shared request budgets.
    func catalogSources(for token: TokenArtworkIdentity) async -> [String] {
        await fallbackCatalog.sources(for: token) ?? []
    }

    public func image(for sources: [String], maxPixelSize: Int? = nil) async -> ArtworkImage? {
        let candidates = ArtworkSource.candidates(sources)
        // Blank optional metadata has no source to resolve. For a rejected
        // candidate, retain its category without copying the URI or image data.
        if candidates.isEmpty, let rejected = sources.prefix(4).lazy
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
            let reason = rejected.prefix(5).lowercased() == "data:" ? "inline_artwork_rejected" : "artwork_uri_rejected"
            OathDiagnostics.record(ArtworkError.invalidSource, component: "artwork", operation: "resolve_source",
                                   severity: "warning", context: ["stage": "source_validation", "reason": reason])
        }
        for source in candidates {
            guard !Task.isCancelled else { return nil }
            let key = ArtworkSource.key(source)
            if let entry = stored(source, maxPixelSize: maxPixelSize), now().timeIntervalSince(entry.fetched) < freshFor { return entry.image }
            if let failed = failures[key], now().timeIntervalSince(failed) < retryAfter { continue }
            let image = await work.value(for: renditionKey(source, maxPixelSize)) {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    await self.download(source, maxPixelSize: maxPixelSize)
                }
            }
            guard !Task.isCancelled else { return nil }
            if let image { return image }
        }
        return cached(for: candidates, maxPixelSize: maxPixelSize)
    }

    private func renditionKey(_ source: String, _ maxPixelSize: Int?) -> String {
        ArtworkSource.key(source) + ":" + (maxPixelSize.map { String(max(1, $0)) } ?? "original")
    }

    private func download(_ source: String, maxPixelSize: Int?) async -> ArtworkImage? {
        guard !Task.isCancelled else { return nil }
        // A queued request may have been filled by another resolution path.
        if let entry = stored(source, maxPixelSize: maxPixelSize), now().timeIntervalSince(entry.fetched) < freshFor { return entry.image }
        var candidates = [source]
        var index = 0
        while index < candidates.count {
            let candidate = candidates[index]
            do {
                try Task.checkCancellation()
                if knownAbsent(candidate) { throw OptionalArtworkAbsent() }
                let data: Data
                if let inline = ArtworkSource.inlineData(candidate) { data = inline }
                else if let url = URL(string: candidate) {
                    let transport = self.transport
                    guard let result = await downloads.value(for: candidate, operation: {
                        do { return .success(try await transport.data(from: url)) }
                        catch {
                            // diagnostics: artwork-flight-propagation. Preserve
                            // the original error for download_decode below,
                            // where optional absence/cancellation are excluded.
                            return .failure(error)
                        }
                    }) else { return nil }
                    data = try result.get()
                }
                else { throw ArtworkError.invalidSource }
                try Task.checkCancellation()
                let image = try ArtworkImage.decode(data, maxPixelSize: maxPixelSize)
                let fetched = now()
                let key = ArtworkSource.key(source)
                memory.setObject(Box(Entry(image: image, fetched: fetched)), forKey: renditionKey(source, maxPixelSize) as NSString, cost: image.memoryCost)
                failures[key] = nil
                // Cache the successful, identity-matched image under the requested
                // source too, so relaunches don't repeat the known missing URL.
                save(DiskEntry(data: data, fetched: fetched), source: source)
                return image
            } catch {
                guard !Task.isCancelled, !OathDiagnostics.isExpectedCancellation(error) else { return nil }
                let absent = error is OptionalArtworkAbsent && ArtworkFallbackCatalog.identity(candidate) != nil
                if absent {
                    rememberAbsence(candidate)
                } else {
                    OathDiagnostics.record(error, component: "artwork", operation: "download_decode",
                        context: ["host": URL(string: candidate)?.host ?? "inline",
                            "source": String(ArtworkSource.key(candidate).prefix(12)),
                            "stage": index == 0 ? "primary" : "fallback"])
                }
                if index == 0, absent || error as? ArtworkError == .http(404) || error as? ArtworkError == .http(410) {
                    let alternatives = await fallbackCatalog.sources(for: source)
                    candidates += ArtworkSource.candidates(alternatives).filter { $0 != source }
                }
            }
            index += 1
        }
        guard !Task.isCancelled else { return nil }
        // Bounded cooldown, never persist a failed download/placeholder.
        failures = failures.filter { now().timeIntervalSince($0.value) < retryAfter }
        if failures.count >= 256, let oldest = failures.min(by: { $0.value < $1.value })?.key { failures[oldest] = nil }
        failures[ArtworkSource.key(source)] = now()
        return nil
    }

    private func absencePath(_ source: String) -> URL {
        directory.appendingPathComponent(ArtworkSource.key(source) + ".missing")
    }
    private func knownAbsent(_ source: String) -> Bool {
        guard ArtworkFallbackCatalog.identity(source) != nil else { return false }
        let file = absencePath(source)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        do {
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 1024 else { throw ArtworkError.oversized }
            let saved = try PropertyListDecoder().decode(Absence.self, from: Data(contentsOf: file))
            let age = now().timeIntervalSince(saved.checked)
            return age >= 0 && age < 24 * 3600
        } catch {
            OathDiagnostics.record(error, component: "artwork", operation: "availability_cache_read")
            _ = OathDiagnostics.attempt("remove_invalid_artwork_availability") { try FileManager.default.removeItem(at: file) }
            return false
        }
    }
    private func rememberAbsence(_ source: String) {
        // Do not refresh the date on a cache hit: a subsequently published logo
        // must become eligible again, even if its row is viewed every day.
        guard !knownAbsent(source) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListEncoder().encode(Absence(checked: now()))
            try data.write(to: absencePath(source), options: .atomic)
            diskIndex.wrote(absencePath(source), bytes: data.count)
        } catch { OathDiagnostics.record(error, component: "artwork", operation: "availability_cache_write") }
    }

    private func stored(_ source: String, maxPixelSize: Int?) -> Entry? {
        let key = ArtworkSource.key(source)
        if let box = memory.object(forKey: renditionKey(source, maxPixelSize) as NSString) { return box.entry }
        let file = path(source)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let saved: DiskEntry, image: ArtworkImage
        var stage = "cache_envelope"
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= ArtworkSource.byteLimit * 2 else { throw ArtworkError.oversized }
            saved = try PropertyListDecoder().decode(DiskEntry.self, from: Data(contentsOf: file))
            stage = "cache_image"
            image = try ArtworkImage.decode(saved.data, maxPixelSize: maxPixelSize)
        } catch {
            OathDiagnostics.record(error, component: "artwork", operation: "cache_read",
                context: ["source": String(key.prefix(12)), "stage": stage])
            _ = OathDiagnostics.attempt("remove_invalid_artwork") { try FileManager.default.removeItem(at: file) }
            return nil
        }
        let entry = Entry(image: image, fetched: saved.fetched)
        memory.setObject(Box(entry), forKey: renditionKey(source, maxPixelSize) as NSString, cost: image.memoryCost)
        diskIndex.touched(file)
        // Touch the file for disk LRU; freshness lives inside the envelope.
        _ = maintainCache("touch_artwork_cache") { try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
        return entry
    }
    private func path(_ source: String) -> URL { directory.appendingPathComponent(ArtworkSource.key(source) + ".artwork") }
    private func save(_ entry: DiskEntry, source: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(entry)
            try data.write(to: path(source), options: .atomic)
            diskIndex.wrote(path(source), bytes: data.count)
        } catch { OathDiagnostics.record(error); /* The in-memory original still works if disk is unavailable. */ }
    }
    private func maintainCache<T>(_ operation: String, body: () throws -> T) -> T? {
        do { return try body() }
        catch CocoaError.fileReadNoSuchFile { return nil } // iOS may purge cache files between inspection and maintenance.
        catch CocoaError.fileNoSuchFile { return nil } // Already absent is a cache miss, not an app failure.
        catch { OathDiagnostics.record(error, component: "artwork", operation: operation); return nil }
    }
}
