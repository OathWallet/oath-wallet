import Foundation
import OathArtworkSource
import OathDiagnostics

/// Public token identity, never a wallet/account identity or a ticker match.
public struct TokenArtworkIdentity: Hashable, Sendable {
    public let networkID: String
    public let reference: String
    public let decimals: Int?
    public static let evmNetworks: Set<String> = [
        "ethereum", "arbitrum", "arc", "avalanche", "base", "bnb", "fantom", "flare",
        "cronos", "gnosis", "linea", "optimism", "polygon", "chiliz", "filecoin", "sei", "zerog", "iotex", "celo", "monad", "unichain", "hyperevm",
        "robinhood", "scroll", "somnia", "story", "taiko", "telos", "xlayer"
    ]
    public init?(networkID: String, reference: String, decimals: Int? = nil) {
        guard !networkID.isEmpty, networkID.count <= 64, !reference.isEmpty,
              reference != "native", reference.utf8.count <= 4096, decimals == nil || (0...255).contains(decimals!) else { return nil }
        self.networkID = networkID
        if networkID == "iotex", reference.lowercased().hasPrefix("io1") {
            guard let address = IoTeXNativeAddress.ethereum(reference) else { return nil }
            self.reference = address
        } else {
            self.reference = Self.evmNetworks.contains(networkID) ? reference.lowercased() : reference
        }
        self.decimals = decimals
    }
    public var assetID: String { networkID + ":" + reference }
    var cacheKey: String { ArtworkSource.key("token-v1:\(networkID.count):\(networkID):\(reference):\(decimals.map(String.init) ?? "unknown")") }
}

public protocol TokenArtworkMetadata: Sendable {
    /// Return only sources validated against this exact network and token.
    /// cachedOnly must never issue a network request.
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String]
}

/// Shares successful artwork across search, saved holdings and detail screens,
/// even when they supply different metadata URLs (or no URL at all).
/// Image bytes remain in ArtworkLoader's bounded, original-quality cache.
public actor TokenArtworkResolver {
    private struct Entry: Codable { let source: String; let saved: Date }
    private struct Request: Hashable { let token: TokenArtworkIdentity; let sources: [String]; let maxPixelSize: Int? }
    private let loader: ArtworkLoader
    private let metadata: any TokenArtworkMetadata
    private let directory: URL
    private var entries: [TokenArtworkIdentity: Entry] = [:]
    private let work = ArtworkWorkPool<Request, ArtworkImage>(concurrency: 12)
    private let metadataWork = ArtworkWorkPool<TokenArtworkIdentity, [String]>(concurrency: 3)
    private let diskIndex: ArtworkDiskIndex
    private var retryAfter: [TokenArtworkIdentity: Date] = [:]
    private struct Observer {
        let continuation: AsyncStream<ArtworkImage>.Continuation
        let maxPixelSize: Int?
        var lastImage: ArtworkImage?
    }
    private var observers: [TokenArtworkIdentity: [UUID: Observer]] = [:]

    public init(loader: ArtworkLoader = .shared, metadata: any TokenArtworkMetadata, directory: URL? = nil) {
        self.loader = loader; self.metadata = metadata
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OathTokenArtworkIdentity-v1", isDirectory: true)
        self.diskIndex = ArtworkDiskIndex(directory: self.directory, extensions: ["plist"],
            byteLimit: 16 * 1024 * 1024, countLimits: ["plist": 512])
    }

    public func cached(for token: TokenArtworkIdentity, sources: [String], maxPixelSize: Int? = nil) async -> ArtworkImage? {
        let saved = entry(for: token).map { [$0.source] } ?? []
        return await loader.cached(for: saved + sources, maxPixelSize: maxPixelSize)
    }

    /// Visible rows receive a newly resolved detail/search image without needing
    /// a balance change, navigation rebuild, or a periodic polling timer.
    public func updates(for token: TokenArtworkIdentity, observerID id: UUID = UUID(), maxPixelSize: Int? = nil) async -> AsyncStream<ArtworkImage> {
        let (stream, continuation) = AsyncStream<ArtworkImage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[token, default: [:]][id] = Observer(continuation: continuation, maxPixelSize: maxPixelSize)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id, token: token) } }
        if let image = await cached(for: token, sources: [], maxPixelSize: maxPixelSize) { deliver(image, token: token, id: id) }
        return stream
    }
    private func removeObserver(_ id: UUID, token: TokenArtworkIdentity) {
        observers[token]?[id] = nil
        if observers[token]?.isEmpty == true { observers[token] = nil }
    }
    /// Explicitly end observers whose view disappears before it starts iterating
    /// (for example, while a shared network request is still in flight).
    public func stopUpdates(for token: TokenArtworkIdentity, observerID: UUID) {
        observers[token]?[observerID]?.continuation.finish()
        removeObserver(observerID, token: token)
    }

    public func image(for token: TokenArtworkIdentity, sources: [String], maxPixelSize: Int? = nil) async -> ArtworkImage? {
        let request = Request(token: token, sources: ArtworkSource.candidates(sources), maxPixelSize: maxPixelSize)
        return await work.value(for: request) {
            await OathDiagnostics.$chain.withValue(token.networkID) {
                await OathDiagnostics.$operationID.withValue(UUID()) { await self.resolve(request) }
            }
        }
    }

    private func resolve(_ request: Request) async -> ArtworkImage? {
        guard !Task.isCancelled else { return nil }
        let token = request.token
        let saved = entry(for: token).map { [$0.source] } ?? []
        // Some on-chain icon URLs outlive their publisher pages. Keep usable
        // cached bytes, then ask the published list for this exact coin identity.
        func prefersCatalog(_ source: String) -> Bool {
            if source == "https://circle.com/usdc-icon" { return true }
            return token.networkID == "sui" && (source == "https://miucoin.io/favicon.ico" || source == "https://winx.io/WIN.svg")
        }
        if let source = saved.first {
            let image = prefersCatalog(source)
                ? await loader.cached(for: [source], maxPixelSize: request.maxPixelSize) : await loader.image(for: [source], maxPixelSize: request.maxPixelSize)
            if let image {
                await remember(source, token: token, image: image, maxPixelSize: request.maxPixelSize)
                return image
            }
        }
        // The detail metadata may already be saved from an earlier app version.
        // Read it before retrying a guessed catalog URL which can be absent.
        guard !Task.isCancelled else { return nil }
        let cachedMetadata = await metadata.sources(for: token, cachedOnly: true)
        guard !Task.isCancelled else { return nil }
        // One published token list covers every visible result on a network.
        // Do not exhaust per-coin metadata limits just to render search logos,
        // then fall through to missing guessed images for the remaining rows.
        let hasRetiredSource = (saved + cachedMetadata + request.sources).contains(where: prefersCatalog)
        let published: [String]
        if hasRetiredSource {
            published = await loader.catalogSources(for: token)
        } else {
            published = cachedMetadata.isEmpty
                ? await loader.catalogSources(for: token, sources: request.sources) : []
        }
        // Discovery knows the public contract before it knows the token scale.
        // Resolve its exact catalog artwork before probing a guessed image path.
        // This never supplies decimals to balances, prices or signing.
        // Saved tokens already have decimals, but their directory-shaped logo
        // is still only a guess. Resolve exact artwork first for those too.
        let hasDirectoryGuess = request.sources.contains { source in
            guard let url = URL(string: source), url.host == "raw.githubusercontent.com" else { return false }
            let path = url.path.split(separator: "/")
            return path.count == 8 && path[0] == "trustwallet" && path[1] == "assets"
                && path[3] == "blockchains" && path[5] == "assets" && path[7] == "logo.png"
        }
        guard !Task.isCancelled else { return nil }
        let discoveryMetadata = (token.decimals == nil || hasDirectoryGuess) && cachedMetadata.isEmpty && published.isEmpty
            ? await metadataSources(for: token) : []
        let candidates = ArtworkSource.candidates(hasRetiredSource
            ? published + saved + cachedMetadata + discoveryMetadata + request.sources
            : saved + cachedMetadata + published + discoveryMetadata + request.sources)
        for source in candidates {
            guard !Task.isCancelled else { return nil }
            if let image = await loader.image(for: [source], maxPixelSize: request.maxPixelSize) {
                await remember(source, token: token, image: image, maxPixelSize: request.maxPixelSize)
                return image
            }
        }
        guard !Task.isCancelled else { return nil }
        let refreshed = await metadataSources(for: token)
        for source in ArtworkSource.candidates(refreshed) where !candidates.contains(source) {
            if let image = await loader.image(for: [source], maxPixelSize: request.maxPixelSize) {
                await remember(source, token: token, image: image, maxPixelSize: request.maxPixelSize)
                return image
            }
        }
        // Missing optional artwork never becomes a persisted placeholder.
        return await cached(for: token, sources: request.sources, maxPixelSize: request.maxPixelSize)
    }

    private func metadataSources(for token: TokenArtworkIdentity) async -> [String] {
        guard !Task.isCancelled else { return [] }
        if let date = retryAfter[token], date > Date() { return [] }
        let metadata = self.metadata
        let sources = await metadataWork.value(for: token) {
            let sources = await metadata.sources(for: token, cachedOnly: false)
            return Task.isCancelled ? nil : sources
        }
        guard !Task.isCancelled, let sources else { return [] }
        retryAfter = retryAfter.filter { $0.value > Date() }
        if retryAfter.count >= 256, let oldest = retryAfter.min(by: { $0.value < $1.value })?.key { retryAfter[oldest] = nil }
        retryAfter[token] = Date().addingTimeInterval(30)
        return sources
    }

    private func path(_ token: TokenArtworkIdentity) -> URL { directory.appendingPathComponent(token.cacheKey + ".plist") }
    private func entry(for token: TokenArtworkIdentity) -> Entry? {
        if let entry = entries[token] { return entry }
        let file = path(token)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= ArtworkSource.byteLimit * 2 else { throw ArtworkError.oversized }
            let entry = try PropertyListDecoder().decode(Entry.self, from: Data(contentsOf: file))
            guard ArtworkSource.normalized(entry.source) != nil else { throw ArtworkError.invalidSource }
            keep(entry, token: token)
            return entry
        } catch {
            OathDiagnostics.record(error, component: "artwork", operation: "identity_cache_read")
            _ = OathDiagnostics.attempt("remove_invalid_artwork_identity") { try FileManager.default.removeItem(at: file) }
            return nil
        }
    }
    private func keep(_ entry: Entry, token: TokenArtworkIdentity) {
        if entries[token] == nil, entries.count >= 256,
           let oldest = entries.min(by: { $0.value.saved < $1.value.saved })?.key { entries[oldest] = nil }
        entries[token] = entry
    }
    private func deliver(_ image: ArtworkImage, token: TokenArtworkIdentity, id: UUID) {
        guard var observer = observers[token]?[id] else { return }
        guard observer.lastImage?.isSameDelivery(as: image) != true else { return }
        observer.lastImage = image
        observers[token]?[id] = observer
        observer.continuation.yield(image)
    }

    private func remember(_ source: String, token: TokenArtworkIdentity, image: ArtworkImage, maxPixelSize: Int?) async {
        guard !Task.isCancelled else { return }
        // Each mounted row receives its own display rendition, once. The URL
        // may stay the same after a repair; compare deliveries, not URL alone.
        for (id, observer) in observers[token] ?? [:] {
            if observer.maxPixelSize == maxPixelSize { deliver(image, token: token, id: id) }
            else if let rendition = await loader.cached(for: [source], maxPixelSize: observer.maxPixelSize) {
                deliver(rendition, token: token, id: id)
            }
        }
        guard !Task.isCancelled, source.utf8.count <= 8192 else { return }
        let changed = entry(for: token)?.source != source || !FileManager.default.fileExists(atPath: path(token).path)
        let entry = Entry(source: source, saved: Date())
        keep(entry, token: token)
        if changed {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let data = try encoder.encode(entry)
                try data.write(to: path(token), options: .atomic)
                diskIndex.wrote(path(token), bytes: data.count)
            } catch { OathDiagnostics.record(error, component: "artwork", operation: "identity_cache_write") }
        }
    }
}
