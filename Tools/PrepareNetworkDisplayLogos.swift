// Host-only: swift Tools/PrepareNetworkDisplayLogos.swift --generate|--check [--networks=plasma,worldchain,elysium]
// Run from the repository root. Originals are never changed.
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("OathApp/Assets.xcassets/Networks")
let outputRoot = root.appendingPathComponent("OathApp/Assets.xcassets/NetworkDisplay")
let manifestURL = root.appendingPathComponent("Design/NetworkLogos/display-manifest.json")
let generate = CommandLine.arguments.contains("--generate")
guard generate || CommandLine.arguments.contains("--check") else {
    fatalError("Specify --generate or --check")
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "NetworkDisplayLogos", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
}
func hash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
func writeJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}
// External volumes can contain AppleDouble sidecars alongside asset folders.
let allSources = try fm.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: [.isDirectoryKey])
    .filter {
        $0.lastPathComponent.hasPrefix("network-") && $0.pathExtension == "imageset"
            && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }.sorted { $0.path < $1.path }
let selected = CommandLine.arguments.first { $0.hasPrefix("--networks=") }.map {
    Set($0.dropFirst("--networks=".count).split(separator: ",").map { "network-" + $0 })
}
let sources = allSources.filter { selected?.contains($0.deletingPathExtension().lastPathComponent) ?? true }
try require(!sources.isEmpty, "No source artwork found")
if let selected { try require(sources.count == selected.count, "Unknown network selection") }
struct ProvidedArtwork: Decodable { let sha256: String; let preserveAlpha: Bool }
let provided = try JSONDecoder().decode([String: ProvidedArtwork].self, from: Data(contentsOf:
    root.appendingPathComponent("Design/NetworkLogos/provided-mainnet-logos.json")))
// A scoped refresh must preserve other chains' existing manifest entries.
var manifest: [String: String] = selected == nil ? [:] : try JSONDecoder().decode(
    [String: String].self, from: Data(contentsOf: manifestURL))
var decodedBytes = 0
if generate {
    try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    try writeJSON(["info": ["author": "xcode", "version": 1]],
                  to: outputRoot.appendingPathComponent("Contents.json"))
}
for directory in sources {
    try autoreleasepool {
        let name = directory.deletingPathExtension().lastPathComponent
        let sourceURL = directory.appendingPathComponent("logo.png")
        let displayDirectory = outputRoot.appendingPathComponent(name + "-display.imageset")
        manifest[name + "/source"] = try hash(sourceURL)
        if let approved = provided[name] {
            try require(manifest[name + "/source"] == approved.sha256, "Provided artwork changed: \(name)")
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw NSError(domain: "NetworkDisplayLogos", code: 2)
        }
        var entries: [[String: String]] = []
        if generate { try fm.createDirectory(at: displayDirectory, withIntermediateDirectories: true) }
        for scale in 1...3 {
            let filename = "logo@\(scale)x.png"
            let target = displayDirectory.appendingPathComponent(filename)
            let pixels = 128 * scale
            if generate {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                      let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil)
                else { throw NSError(domain: "NetworkDisplayLogos", code: 3) }
                // Small upstream logos still need correctly sized 3x renditions.
                // ImageIO thumbnails never upscale by themselves.
                if image.width != pixels || image.height != pixels {
                    guard let scaled = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw NSError(domain: "NetworkDisplayLogos", code: 3)
                    }
                    scaled.interpolationQuality = .high
                    scaled.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                    guard let output = scaled.makeImage() else { throw NSError(domain: "NetworkDisplayLogos", code: 3) }
                    CGImageDestinationAddImage(destination, output, nil)
                } else { CGImageDestinationAddImage(destination, image, nil) }
                try require(CGImageDestinationFinalize(destination), "Failed to write \(name)")
            }
            guard let rendition = CGImageSourceCreateWithURL(target as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(rendition, 0, nil) else {
                throw NSError(domain: "NetworkDisplayLogos", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Missing rendition: \(target.path)"])
            }
            try require(image.width == pixels && image.height == pixels, "Unexpected square dimensions: \(name)")
            // A square background must fill the entire canvas. Accept RGB and
            // RGBA files, but reject residual transparent circular corners.
            guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                          bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data else {
                throw NSError(domain: "NetworkDisplayLogos", code: 5)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            let rgba = data.assumingMemoryBound(to: UInt8.self)
            if provided[name]?.preserveAlpha == true {
                // Explicitly supplied PNGs retain their own rounded silhouette.
                // Their approved source hashes prevent a broad opacity exclusion.
                let corners = [0, pixels - 1, (pixels - 1) * pixels, pixels * pixels - 1]
                try require(corners.allSatisfy { rgba[$0 * 4 + 3] == 0 }
                    && rgba[((pixels / 2) * pixels + pixels / 2) * 4 + 3] == 255,
                    "Provided silhouette lost transparency or content: \(name)")
            } else {
                try require((0..<(pixels * pixels)).allSatisfy { rgba[$0 * 4 + 3] == 255 },
                            "Square artwork must be fully opaque: \(name)")
            }
            if scale == 3 { decodedBytes += image.bytesPerRow * image.height }
            manifest[name + "/" + filename] = try hash(target)
            entries.append(["filename": filename, "idiom": "universal", "scale": "\(scale)x"])
        }
        let contentsURL = displayDirectory.appendingPathComponent("Contents.json")
        if generate {
            try writeJSON(["images": entries, "info": ["author": "xcode", "version": 1],
                           "properties": ["template-rendering-intent": "original"]], to: contentsURL)
        }
        let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: contentsURL)) as? [String: Any]
        try require(contents?["images"] as? [[String: String]] == entries, "Incorrect catalog scales: \(name)")
    }
}
if generate { try writeJSON(manifest, to: manifestURL) }
let savedManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: String]
try require(savedManifest == manifest, "Display artwork is stale; run --generate after changing source logos")
print("Validated \(sources.count) logos at 1x/2x/3x; total 3x decoded footprint: \(decodedBytes / 1024) KiB")
