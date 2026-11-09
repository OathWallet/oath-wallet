import Foundation
import OathDiagnostics

/// Actor-confined accounting: inspect the directory once, then account for each
/// write. Scrolling must not enumerate/stat/sort the entire cache per new logo.
final class ArtworkDiskIndex {
    private struct File { let size: Int; var date: Date }
    private let directory: URL
    private let extensions: Set<String>
    private let byteLimit: Int
    private let countLimits: [String: Int]
    private var files: [URL: File] = [:]
    private var counts: [String: Int] = [:]
    private var total = 0
    private var loaded = false
    private(set) var scans = 0

    init(directory: URL, extensions: Set<String>, byteLimit: Int, countLimits: [String: Int]) {
        self.directory = directory; self.extensions = extensions
        self.byteLimit = byteLimit; self.countLimits = countLimits
    }

    func wrote(_ url: URL, bytes: Int) {
        do {
            if !loaded {
                scans += 1
                let urls = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
                var initial: [URL: File] = [:]
                for file in urls where extensions.contains(file.pathExtension) {
                    do {
                        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        initial[file] = File(size: values.fileSize ?? 0, date: values.contentModificationDate ?? .distantPast)
                    } catch CocoaError.fileReadNoSuchFile { /* Cache purged concurrently. */ }
                }
                files = initial; total = initial.values.reduce(0) { $0 + $1.size }; loaded = true
                counts = Dictionary(grouping: initial.keys, by: \.pathExtension).mapValues(\.count)
            }
            if files[url] == nil { counts[url.pathExtension, default: 0] += 1 }
            total += bytes - (files[url]?.size ?? 0)
            files[url] = File(size: bytes, date: .now)
            guard total > byteLimit || countLimits.contains(where: { counts[$0.key, default: 0] > $0.value }) else { return }
            for (file, info) in files.sorted(by: { $0.value.date < $1.value.date }) {
                let ext = file.pathExtension
                guard total > byteLimit || counts[ext, default: 0] > countLimits[ext, default: Int.max] else { continue }
                do { try FileManager.default.removeItem(at: file) }
                catch CocoaError.fileNoSuchFile { /* An already purged cache entry is absent. */ }
                catch CocoaError.fileReadNoSuchFile { /* An already purged cache entry is absent. */ }
                files[file] = nil; total -= info.size; counts[ext, default: 0] -= 1
            }
        } catch { OathDiagnostics.record(error, component: "artwork", operation: "cache_maintenance") }
    }

    func touched(_ url: URL) { files[url]?.date = .now }
}
