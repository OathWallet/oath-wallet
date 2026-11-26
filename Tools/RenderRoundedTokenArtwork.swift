// Host-only SwiftUI preview using the production decoder, palette and view.
// Link against the OathTokenImages host build; arguments: source folder, output folder.
import AppKit
import SwiftUI
import ImageIO
import OathTokenImages

@main struct RoundedTokenPreview {
    @MainActor static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let names = ["USDT", "USDC", "DAI", "WETH", "WBTC", "LINK", "UNI", "AAVE", "COMP", "MKR", "SHIB", "SUSHI", "CRV", "GRT", "ENS"]
        let images = try names.map { try ArtworkImage.decode(Data(contentsOf: source.appendingPathComponent($0 + ".png"))) }
        for dark in [false, true] {
            let width = 1400, height = 850
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: dark ? 0.06 : 0.97, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            func text(_ value: String, x: Int, y: Int, size: CGFloat = 20) {
                (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: size), .foregroundColor: dark ? NSColor.white : NSColor.black])
            }
            text("Original token artwork → Native rounded-square presentation", x: 24, y: 800, size: 25)
            for (index, artwork) in images.enumerated() {
                let x = (index % 5) * 280, y = 760 - (index / 5 + 1) * 240
                let before = ImageRenderer(content: ArtworkImageView(artwork).frame(width: 38, height: 38).clipShape(Circle()))
                let after = ImageRenderer(content: TokenArtworkView(artwork, size: 38))
                before.scale = 3; after.scale = 3
                context.interpolationQuality = .none
                context.draw(before.cgImage!, in: CGRect(x: x + 15, y: y + 80, width: 114, height: 114))
                context.draw(after.cgImage!, in: CGRect(x: x + 151, y: y + 80, width: 114, height: 114))
                text(names[index], x: x + 16, y: y + 30)
            }
            NSGraphicsContext.restoreGraphicsState()
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("preview-\(dark ? "dark" : "light").png") as CFURL,
                                                               "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
        print("Rendered 15 real token fixtures with the production SwiftUI treatment; no simulator or device used.")
    }
}
