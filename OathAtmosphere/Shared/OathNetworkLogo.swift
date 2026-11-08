import SwiftUI
import UIKit
import OathTokenImages

/// The shared presentation for bundled network and asset artwork.
/// Full-bleed network artwork gets one antialiased, continuous rounded-square
/// mask at its final display size. Other bundled artwork keeps its silhouette.
struct OathNetworkLogo: View {
    let asset: String
    let size: CGFloat

    private var resolvedAsset: String { Self.resolvedAsset(asset) }

    // Reuse prepared local artwork across picker presentations. A cache miss
    // or memory-pressure eviction is expected and never a diagnostic failure.
    @MainActor private static let renderedImages: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    static func resolvedAsset(_ asset: String) -> String {
        guard asset.hasPrefix("network-") else { return asset }
        let network = String(asset.dropFirst("network-".count))
        return OathReceiveExampleCatalog.bundled.redesignedArtwork(networkID: network, reference: "native") ?? asset
    }

    /// UIKit accessories must use the same artwork, mask and display resolution
    /// as SwiftUI rows. A 20-pixel thumbnail becomes blurry at 20pt on Retina.
    @MainActor static func renderedImage(asset: String, size: CGFloat, scale: CGFloat) -> UIImage? {
        let resolved = resolvedAsset(asset)
        let displayScale = max(1, scale)
        let key = "\(resolved):\(size):\(displayScale)" as NSString
        if let image = renderedImages.object(forKey: key) { return image }
        guard UIImage(named: resolved + "-display") != nil || UIImage(named: resolved) != nil else { return nil }
        let renderer = ImageRenderer(content: OathNetworkLogo(asset: asset, size: size))
        renderer.scale = displayScale
        guard let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal) else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        renderedImages.setObject(image, forKey: key, cost: cost)
        return image
    }

    private var artwork: Image {
        // Pre-sized catalog renditions avoid decoding/uploading a 4K texture
        // when a small row or badge enters the viewport. UIKit caches these
        // named images; larger artwork still uses the preserved source.
        if size <= 128, let displayImage = UIImage(named: resolvedAsset + "-display") {
            return Image(uiImage: displayImage)
        }
        // Optional display artwork may be absent for non-network assets.
        return Image(resolvedAsset)
    }

    var body: some View {
        artwork
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(
                RoundedRectangle(cornerRadius: resolvedAsset.hasPrefix("network-") ? size * TokenArtworkStyle.cornerRadiusFraction : 0,
                                 style: .continuous),
                style: FillStyle(antialiased: true)
            )
            .accessibilityHidden(true)
    }
}
