import Foundation
import CryptoKit
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers
import OathDiagnostics

/// Per-origin thumbnails for saved favorites. The conventional icon request
/// remains a fallback for pages without an icon in their link metadata.
public actor BrowserFavoriteIcons {
    private let directory: URL
    private let session: URLSession
    private static let headByteLimit = 256 * 1024
    private static let iconByteLimit = 1024 * 1024
    private static let linkIconByteLimit = 4 * 1024 * 1024
    private static let thumbnailByteLimit = 64 * 1024

    public init(directory: URL) {
        self.init(directory: directory, configuration: .ephemeral)
    }

    init(directory: URL, configuration config: URLSessionConfiguration) {
        self.directory = directory
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 8
        session = URLSession(configuration: config, delegate: FavoriteIconRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func cached(for origin: BrowserOrigin) -> Data? {
        let file = iconFile(for: origin)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (1...Self.thumbnailByteLimit).contains(size) else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: file)
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetStatus(source) == .statusComplete else { throw CocoaError(.fileReadCorruptFile) }
            return data
        } catch {
            OathDiagnostics.record(DiagnosticFailure("Favorite icon cache read failed"), component: "browser",
                                   operation: "read_favorite_icon", context: ["code": String((error as NSError).code)])
            return nil
        }
    }

    /// Called when the bookmark collection changes, including eviction at its limit of 200.
    public func keepOnly(_ origins: Set<BrowserOrigin>) {
        let files = FileManager.default
        guard !Task.isCancelled, files.fileExists(atPath: directory.path) else { return }
        let kept = Set(origins.map { iconFile(for: $0).lastPathComponent })
        do {
            for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            where file.pathExtension == "png" && !kept.contains(file.lastPathComponent) {
                try files.removeItem(at: file)
            }
        } catch {
            OathDiagnostics.record(DiagnosticFailure("Favorite icon cache cleanup failed"), component: "browser",
                                   operation: "prune_favorite_icons", context: ["code": String((error as NSError).code)])
        }
    }

    private func iconFile(for origin: BrowserOrigin) -> URL {
        let key = SHA256.hash(data: Data(origin.string.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".png")
    }

    public func metadata(for url: URL, needsTitle: Bool) async -> (title: String?, icon: Data?) {
        guard let page = BrowserPolicy.restorable(url), let origin = try? BrowserOrigin(page) else { return (nil, nil) }
        let saved = cached(for: origin)
        if saved != nil && !needsTitle { return (nil, saved) }
        var title: String?
        var icon = saved
        var iconOrigin = origin
        if let (data, response) = await resource(at: page, headOnly: true), let final = response.url {
            let encoding = response.textEncodingName ?? (String(data: data, encoding: .utf8) == nil ? nil : "UTF-8")
            let head = BrowserPageMetadata(html: data, url: final, encoding: encoding)
            title = head.title
            iconOrigin = (try? BrowserOrigin(final)) ?? origin
            if icon == nil {
                for url in head.icons {
                    icon = await fetchIcon(at: url)
                    if icon != nil || Task.isCancelled { break }
                }
            }
        }
        if icon == nil, let base = URL(string: iconOrigin.string) {
            icon = await fetchIcon(at: base.appendingPathComponent("favicon.ico"))
        }
        if !Task.isCancelled, icon == nil || (needsTitle && title == nil) {
            let link = await Self.linkMetadata(for: page, needsIcon: icon == nil)
            title = title ?? link.title
            icon = icon ?? link.icon
        }
        guard !Task.isCancelled else { return (nil, nil) }
        if saved == nil, let icon { store(icon, for: origin) }
        return (title, icon)
    }

    @MainActor private static func linkMetadata(for page: URL, needsIcon: Bool) async -> (title: String?, icon: Data?) {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        provider.shouldFetchSubresources = needsIcon
        var request = URLRequest(url: page)
        request.httpShouldHandleCookies = false
        let operationID = OathDiagnostics.operationID
        let cancel: @MainActor @Sendable () -> Void = { provider.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    provider.startFetchingMetadata(for: request) { metadata, error in
                        if let error { continuation.resume(throwing: error); return }
                        guard let metadata, let final = metadata.url, (try? BrowserOrigin(final)) != nil else {
                            continuation.resume(returning: (nil, nil))
                            return
                        }
                        let title = BrowserPageRecord.pageTitle(metadata.title, for: final)
                        guard needsIcon, let icon = metadata.iconProvider,
                              let type = icon.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                            continuation.resume(returning: (title, nil))
                            return
                        }
                        icon.loadFileRepresentation(forTypeIdentifier: type) { file, error in
                            let png = OathDiagnostics.$operationID.withValue(operationID) { Self.linkIcon(at: file, error: error) }
                            continuation.resume(returning: (title, png))
                        }
                    }
                }
            } onCancel: { Task { @MainActor in cancel() } }
        } catch {
            if !Task.isCancelled {
                OathDiagnostics.record(DiagnosticFailure("Favorite link metadata request failed"), component: "browser",
                                       operation: "fetch_favorite_metadata", context: ["code": String((error as NSError).code)])
            }
            return (nil, nil)
        }
    }

    private static func linkIcon(at file: URL?, error: Error?) -> Data? {
        do {
            if let error { throw error }
            guard let file, let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (1...linkIconByteLimit).contains(size) else { return nil }
            return thumbnail(try Data(contentsOf: file, options: .mappedIfSafe))
        } catch {
            OathDiagnostics.record(DiagnosticFailure("Favorite link icon could not be read"), component: "browser",
                                   operation: "read_link_icon", context: ["code": String((error as NSError).code)])
            return nil
        }
    }

    public func iconForVisit(to origin: BrowserOrigin) async -> Data? {
        if let saved = cached(for: origin) { return saved }
        guard let base = URL(string: origin.string), (try? BrowserOrigin(base)) == origin,
              let png = await fetchIcon(at: base.appendingPathComponent("favicon.ico")), !Task.isCancelled else { return nil }
        store(png, for: origin)
        return png
    }

    private func fetchIcon(at url: URL) async -> Data? {
        guard let (data, _) = await resource(at: url, headOnly: false) else { return nil }
        return Self.thumbnail(data)
    }

    private func resource(at url: URL, headOnly: Bool) async -> (Data, HTTPURLResponse)? {
        guard !Task.isCancelled, (try? BrowserOrigin(url)) != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                  (try? BrowserOrigin(finalURL)) != nil else { return nil }
            // Websites may omit an icon or decline link previews.
            if [404, 410].contains(http.statusCode) { return nil }
            guard http.statusCode == 200 else {
                // The shared HTTP diagnostic needs only the status, never a bookmarked host.
                DiagnosticHTTP.response(Data(), status: http.statusCode, request: URLRequest(url: URL(fileURLWithPath: "/")))
                return nil
            }
            let limit = headOnly ? Self.headByteLimit : Self.iconByteLimit
            if headOnly {
                guard ["text/html", "application/xhtml+xml"].contains(http.mimeType ?? "") else { return nil }
            } else {
                guard http.expectedContentLength <= limit,
                      http.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") != true else { return nil }
            }
            var data = Data()
            for try await byte in bytes {
                if data.count == limit {
                    if headOnly { break }
                    return nil
                }
                data.append(byte)
            }
            return Task.isCancelled ? nil : (data, http)
        } catch {
            if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                OathDiagnostics.record(DiagnosticFailure("Favorite resource request failed"), component: "browser",
                                       operation: headOnly ? "fetch_favorite_head" : "fetch_favorite_icon",
                                       context: ["code": String((error as NSError).code)])
            }
            return nil
        }
    }

    private func store(_ png: Data, for origin: BrowserOrigin) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try png.write(to: iconFile(for: origin), options: [.atomic, .completeFileProtection])
            #else
            try png.write(to: iconFile(for: origin), options: .atomic)
            #endif
        } catch {
            OathDiagnostics.record(DiagnosticFailure("Favorite icon cache write failed"), component: "browser",
                                   operation: "save_favorite_icon", context: ["code": String((error as NSError).code)])
        }
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= linkIconByteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder), result.length <= thumbnailByteLimit else { return nil }
        return result as Data
    }
}

private final class FavoriteIconRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, (try? BrowserOrigin(next)) != nil else {
            completionHandler(nil)
            return
        }
        var nextRequest = request
        nextRequest.httpShouldHandleCookies = false
        nextRequest.setValue(nil, forHTTPHeaderField: "Referer")
        completionHandler(nextRequest)
    }
}
