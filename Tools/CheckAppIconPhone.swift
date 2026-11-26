import AppKit
import SwiftUI

// Host-only regression: swiftc OathAtmosphere/Preferences/OathIconPhonePreview.swift
// Tools/CheckAppIconPhone.swift -o /tmp/oath-icon-phone-check && /tmp/oath-icon-phone-check
@main enum CheckAppIconPhone {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        for width in [320.0, 402.0, 440.0, 600.0] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: 650)
            let phone = OathIconPhoneGeometry(in: bounds)
            let screen = OathIconPhoneDisplay().path(in: bounds)
            check(phone.chassis.contains(phone.bezel), "Bezel must stay within chassis")
            check(phone.bezel.contains(phone.display), "Display must stay inside bezel")
            check(!screen.contains(CGPoint(x: phone.chassis.minX, y: 300)), "Hardware is outside display")
            check(!screen.contains(CGPoint(x: phone.display.minX + 1, y: 0)), "Rounded top corner excludes icons")
            check(screen.contains(CGPoint(x: width / 2, y: 300)), "Centered icon remains visible")

            // Exercise out-of-bounds icon content, including shadows and blur,
            // at rest and while crossing the left edge during a swipe.
            for center in [0.0, width / 2] {
                let renderer = ImageRenderer(content:
                    Rectangle().fill(.red).frame(width: width * 2, height: 160)
                        .blur(radius: 8).shadow(color: .red, radius: 16)
                        .position(x: center, y: 300)
                        .frame(width: width, height: 650)
                        .clipShape(OathIconPhoneDisplay()))
                renderer.scale = 1
                guard let image = renderer.cgImage else { preconditionFailure("Mask failed to render") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                for y in stride(from: 200, through: 400, by: 10) {
                    for x in [0, Int(phone.chassis.minX + phone.metalWidth / 2), Int(phone.display.minX) - 2] {
                        check((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.001,
                              "Icon blur/shadow must never paint outside the glass")
                    }
                }
                check((bitmap.colorAt(x: Int(width / 2), y: 300)?.alphaComponent ?? 0) > 0.99,
                      "Mask must not remove the centered icon")
            }
        }
        print("Passed \(checks) native phone geometry and rendered clipping checks on the Mac host.")
    }
}
