import Foundation
import OathDiagnostics

public struct BrowserPageRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var visitedAt: Date
    /// Only bookmarks use these fields. Both are absent in older archives.
    public var isCustomTitle: Bool?
    public var metadataAttemptedAt: Date?
    public init(id: UUID = UUID(), url: URL, title: String = "", visitedAt: Date = .now) {
        self.id = id; self.url = url; self.title = String(title.prefix(160)); self.visitedAt = visitedAt
    }

    public static func pageTitle(_ value: String?, for url: URL) -> String? {
        guard let value else { return nil }
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lower = text.lowercased()
        let host = url.host?.lowercased() ?? ""
        guard !text.isEmpty, lower != host, lower != host + "/",
              !lower.hasPrefix("https://"), !lower.hasPrefix("http://") else { return nil }
        return String(text.prefix(160))
    }

    public var hasCustomTitle: Bool { isCustomTitle ?? (Self.pageTitle(title, for: url) != nil) }

    public var displayTitle: String {
        if isCustomTitle == true, !title.isEmpty { return title }
        if let title = Self.pageTitle(title, for: url) { return title }
        let labels = (url.host ?? "").split(separator: ".")
        let name = labels.first { !["www", "app", "m"].contains($0.lowercased()) } ?? labels.first ?? ""
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
public struct BrowserSession: Codable, Equatable, Sendable {
    public enum Screen: String, Codable, Sendable { case page, tabs }
    public var selectedTabID: UUID?
    public let screen: Screen
    public let showsLibrary: Bool

    public init(selectedTabID: UUID?, screen: Screen, showsLibrary: Bool = false) {
        self.selectedTabID = selectedTabID
        self.screen = screen
        self.showsLibrary = showsLibrary
    }
}

public struct BrowserArchive: Codable, Equatable, Sendable {
    public var tabs: [BrowserPageRecord] = []
    public var bookmarks: [BrowserPageRecord] = []
    public var history: [BrowserPageRecord] = []
    public var permissions: [BrowserPermission] = []
    /// Older archives stored only the tab list.
    public var session: BrowserSession?
    public init() {}

    @discardableResult
    public mutating func addBookmark(url: URL, title: String, customTitle: Bool = true) -> BrowserPageRecord? {
        guard let safe = BrowserPolicy.restorable(url) else { return nil }
        let existing = bookmarks.first { BrowserPolicy.samePage($0.url, safe) }
        var record = existing ?? BrowserPageRecord(url: safe)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if customTitle && !name.isEmpty {
            record.title = String(name.prefix(160))
            record.isCustomTitle = true
        } else if !record.hasCustomTitle {
            let visit = history.first { BrowserPolicy.samePage($0.url, safe) }
            record.title = BrowserPageRecord.pageTitle(name, for: safe)
                ?? BrowserPageRecord.pageTitle(visit?.title, for: safe) ?? record.title
            record.isCustomTitle = false
        }
        record.url = safe
        record.visitedAt = .now
        bookmarks.removeAll { BrowserPolicy.samePage($0.url, safe) }
        bookmarks.insert(record, at: 0)
        if bookmarks.count > 200 { bookmarks.removeLast(bookmarks.count - 200) }
        return record
    }

    public mutating func recordVisit(to url: URL, title: String?) {
        guard let safe = BrowserPolicy.restorable(url) else { return }
        var visit = history.first { BrowserPolicy.samePage($0.url, safe) } ?? BrowserPageRecord(url: safe)
        history.removeAll { BrowserPolicy.samePage($0.url, safe) }
        visit.url = safe
        visit.visitedAt = .now
        if let name = BrowserPageRecord.pageTitle(title, for: url) { visit.title = name }
        history.insert(visit, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }

    /// A late WebKit title may update an existing visit, including after a single-page
    /// navigation. It must never recreate a visit the user has already removed.
    @discardableResult
    public mutating func updatePageTitle(_ title: String?, for url: URL) -> Bool {
        guard let safe = BrowserPolicy.restorable(url), let name = BrowserPageRecord.pageTitle(title, for: url) else { return false }
        var changed = false
        if let i = history.firstIndex(where: { BrowserPolicy.samePage($0.url, safe) }), history[i].title != name {
            history[i].title = name
            changed = true
        }
        if let i = bookmarks.firstIndex(where: { BrowserPolicy.samePage($0.url, safe) }),
           !bookmarks[i].hasCustomTitle, bookmarks[i].title != name {
            bookmarks[i].isCustomTitle = false
            bookmarks[i].title = name
            changed = true
        }
        return changed
    }

    public mutating func removeVisit(_ id: UUID) {
        guard let page = history.first(where: { $0.id == id }) else { return }
        history.removeAll { BrowserPolicy.samePage($0.url, page.url) }
    }

    public mutating func clearHistory() {
        history.removeAll()
    }

    public var lastSession: BrowserSession? {
        if let id = session?.selectedTabID, tabs.contains(where: { $0.id == id }) { return session }
        // Old archives timestamped every tab when saving. History identifies
        // the last visited website more reliably for those installations.
        let lastVisit = history.first { page in tabs.contains { $0.url == page.url } }
        let tab = lastVisit.flatMap { visit in tabs.first { $0.url == visit.url } }
            ?? tabs.max { $0.visitedAt < $1.visitedAt }
        guard tab != nil || session?.screen == .tabs else { return nil }
        return BrowserSession(selectedTabID: tab?.id, screen: session?.screen ?? .page,
                              showsLibrary: session?.showsLibrary ?? false)
    }

    public mutating func normalize(now: Date = .now) {
        func pages(_ rows: [BrowserPageRecord], limit: Int) -> [BrowserPageRecord] {
            var ids = Set<UUID>()
            return Array(rows.compactMap { row in
                guard ids.insert(row.id).inserted, let url = BrowserPolicy.restorable(row.url) else { return nil }
                var safe = row
                safe.url = url
                safe.title = String(row.title.prefix(160))
                safe.visitedAt = min(row.visitedAt, now)
                safe.metadataAttemptedAt = row.metadataAttemptedAt.map { min($0, now) }
                return safe
            }.prefix(limit))
        }
        tabs = pages(tabs, limit: BrowserPolicy.maximumTabs)
        bookmarks = pages(bookmarks, limit: 200)
        history = pages(history.filter { now.timeIntervalSince($0.visitedAt) < 30 * 86400 }, limit: 500)
        if session != nil { session = lastSession }
        permissions = Array(permissions.filter { permission in
            guard let url = URL(string: permission.origin.string) else { return false }
            return (try? BrowserOrigin(url)) == permission.origin
        }.prefix(200))
    }
}

/// Thumbnails are bound to the exact page that was rendered. A sanitized
/// callback URL must never restore an image of the original callback page.
public struct BrowserTabPreview: Codable, Equatable, Sendable {
    public static let maximumBytes = 128 * 1024
    public let url: URL
    public let jpeg: Data

    public init?(url: URL, jpeg: Data) {
        guard BrowserPolicy.restorable(url) == url, !jpeg.isEmpty, jpeg.count <= Self.maximumBytes else { return nil }
        self.url = url
        self.jpeg = jpeg
    }
}

/// Separate local metadata, excluded from backup. This is OS-protected storage,
/// not a claim of app-passcode encryption. Private pages never reach this API.
public actor BrowserStorage {
    private let url: URL
    private var previewURL: URL { url.deletingLastPathComponent().appendingPathComponent("tab-previews-v1.plist") }
    private var writtenPreviews: [UUID: BrowserTabPreview]?
    public init(url: URL) { self.url = url }
    public func load() -> BrowserArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() } // Expected first launch.
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
            var archive = try JSONDecoder().decode(BrowserArchive.self, from: Data(contentsOf: url))
            archive.normalize(); return archive
        } catch { OathDiagnostics.record(StorageFailure.read, component: "browser", operation: "load_metadata"); return .init() }
    }
    public func restoreTabs() -> (archive: BrowserArchive, previews: [UUID: BrowserTabPreview]) {
        let archive = load()
        guard FileManager.default.fileExists(atPath: previewURL.path) else { return (archive, [:]) }
        do {
            guard try previewURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 1_200_000 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let previews = try PropertyListDecoder().decode([UUID: BrowserTabPreview].self, from: Data(contentsOf: previewURL))
            writtenPreviews = previews
            let current = matching(previews, tabs: archive.tabs)
            writePreviews(current)
            return (archive, current)
        } catch {
            OathDiagnostics.record(StorageFailure.read, component: "browser", operation: "read_tab_previews",
                                   context: ["code": String((error as NSError).code)])
            return (archive, [:])
        }
    }

    public func save(_ archive: BrowserArchive, tabPreviews: [UUID: BrowserTabPreview]? = nil) throws {
        do {
            var safe = archive; safe.normalize()
            var folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
            let data = try JSONEncoder().encode(safe)
            guard data.count <= 2_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            if let previews = tabPreviews ?? writtenPreviews {
                writePreviews(matching(previews, tabs: safe.tabs))
            } else if safe.tabs.isEmpty { writePreviews([:]) }
        } catch { OathDiagnostics.record(StorageFailure.write, component: "browser", operation: "save_metadata"); throw StorageFailure.write }
    }

    private func matching(_ previews: [UUID: BrowserTabPreview], tabs: [BrowserPageRecord]) -> [UUID: BrowserTabPreview] {
        var result: [UUID: BrowserTabPreview] = [:]
        for tab in tabs.prefix(BrowserPolicy.maximumTabs) {
            guard let preview = previews[tab.id], preview.url == tab.url, BrowserPolicy.restorable(preview.url) == preview.url,
                  !preview.jpeg.isEmpty, preview.jpeg.count <= BrowserTabPreview.maximumBytes else { continue }
            result[tab.id] = preview
        }
        return result
    }

    private func writePreviews(_ previews: [UUID: BrowserTabPreview]) {
        guard writtenPreviews != previews else { return }
        do {
            if previews.isEmpty {
                if FileManager.default.fileExists(atPath: previewURL.path) { try FileManager.default.removeItem(at: previewURL) }
            } else {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(previews)
                #if os(iOS)
                try data.write(to: previewURL, options: [.atomic, .completeFileProtection])
                #else
                try data.write(to: previewURL, options: .atomic)
                #endif
            }
            writtenPreviews = previews
        } catch {
            OathDiagnostics.record(StorageFailure.write, component: "browser", operation: "save_tab_previews",
                                   context: ["code": String((error as NSError).code)])
        }
    }
    // Metadata may contain arbitrary URLs/titles. Never report decoder paths or file contents.
    private enum StorageFailure: Error { case read, write }
}
