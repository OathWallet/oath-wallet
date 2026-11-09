import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
#if canImport(OathDatabase)
import OathDatabase

/// The payload is always the wallet address, never an example token contract.
/// Cache and share an opaque black-on-white image. The on-screen artwork below
/// removes its white pixels without changing the encoded payload or quiet zone.
enum OathReceiveQRCode {
    // Shared with the on-screen badge and host decoding checks. Keep the logo
    // inside this small protected center; never cover the finder/quiet zones.
    static let displaySide: CGFloat = 320
    static let badgeFraction = ReceiveQRImage.badgeFraction
    static let logoFraction = ReceiveQRImage.logoFraction

    static func image(for address: String) -> CGImage? {
        ReceiveQRImage.image(for: address)
    }

    static func centeredRect(in bounds: CGRect, fraction: CGFloat) -> CGRect {
        let side = min(bounds.width, bounds.height) * fraction
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }
}

/// Display only the QR modules, in the appearance's primary color. The quiet
/// zone and logo clearance remain transparent instead of forming a white card.
/// Keep the cached/exported image unchanged for receiving apps and printouts.
struct OathReceiveQRArtwork<Logo: View>: View {
    let image: CGImage
    let badgeCornerRadiusFraction: CGFloat
    @ViewBuilder let logo: (CGFloat) -> Logo

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let badgeSide = side * OathReceiveQRCode.badgeFraction
            Rectangle()
                .fill(.primary)
                .mask {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none).resizable().scaledToFit()
                        .overlay {
                            // Clear the existing center, including older circular
                            // cutouts, before converting white to transparency.
                            RoundedRectangle(cornerRadius: badgeSide * badgeCornerRadiusFraction,
                                             style: .continuous)
                                .fill(.white)
                                .frame(width: badgeSide, height: badgeSide)
                        }
                        .compositingGroup()
                        .colorInvert()
                        .luminanceToAlpha()
                }
                .overlay { logo(side * OathReceiveQRCode.logoFraction) }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
#endif

/// Sensitive payloads stay in memory; no image file, URL or shared cache.
enum OathPrivateKeyQRCode {
    static func image(for key: String) -> CGImage? { OathQRCode.image(payload: key) }
}

private enum OathQRCode {
    static func image(payload: String, correctionLevel: String = "M",
                      context: CIContext = CIContext(options: [.cacheIntermediates: false])) -> CGImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        let quietZone = output.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: quietZone)
        let image = output.composited(over: white).transformed(by: .init(scaleX: 8, y: 8))
        return context.createCGImage(image, from: image.extent)
    }
}
