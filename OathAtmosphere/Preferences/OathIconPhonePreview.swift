import SwiftUI

/// A close crop of a portrait phone. The chassis, bezel and display share one
/// geometry, so carousel effects cannot spill onto the hardware at any size.
struct OathIconPhoneGeometry {
    let chassis: CGRect
    let bezel: CGRect
    let display: CGRect
    let cornerRadius: CGFloat
    let metalWidth: CGFloat
    let glassLip: CGFloat

    init(in bounds: CGRect) {
        let width = max(1, bounds.width)
        let phoneWidth = width * 1.92
        chassis = CGRect(x: bounds.minX + width * 0.035, y: bounds.minY - width * 0.07,
                         width: phoneWidth, height: phoneWidth * 2.17)
        cornerRadius = phoneWidth * 0.16
        metalWidth = width * 0.038
        glassLip = width * 0.016
        bezel = chassis.insetBy(dx: metalWidth, dy: metalWidth)
        display = bezel.insetBy(dx: glassLip, dy: glassLip)
    }

    var chassisPath: Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: chassis)
    }
    var bezelPath: Path {
        RoundedRectangle(cornerRadius: cornerRadius - metalWidth, style: .continuous).path(in: bezel)
    }
    var displayPath: Path {
        RoundedRectangle(cornerRadius: cornerRadius - metalWidth - glassLip, style: .continuous).path(in: display)
    }
}

/// The exact display boundary used by the native SwiftUI phone preview.
struct OathIconPhoneDisplay: Shape {
    func path(in rect: CGRect) -> Path { OathIconPhoneGeometry(in: rect).displayPath }
}

struct OathIconPhoneFrame: View {
    let background: Color

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let phone = OathIconPhoneGeometry(in: bounds)
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                // Continuous rounded corners form a real screen aperture,
                // rather than an open decorative stroke over the icons.
                phone.chassisPath.fill(LinearGradient(stops: [
                    .init(color: Color(red: 0.36, green: 0.39, blue: 0.48), location: 0),
                    .init(color: Color(red: 0.72, green: 0.75, blue: 0.86), location: 0.16),
                    .init(color: Color(red: 0.37, green: 0.41, blue: 0.52), location: 0.42),
                    .init(color: Color(red: 0.62, green: 0.67, blue: 0.79), location: 0.66),
                    .init(color: Color(red: 0.18, green: 0.20, blue: 0.25), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                phone.chassisPath.stroke(.white.opacity(0.35), lineWidth: 1)
                phone.bezelPath.fill(.black)
                phone.bezelPath.stroke(.white.opacity(0.18), lineWidth: 0.7)
                phone.displayPath.fill(background)
                phone.displayPath.fill(LinearGradient(colors: [.white.opacity(0.025), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

                Capsule().fill(.black.opacity(0.9))
                    .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.7) }
                    .frame(width: width * 0.012, height: width * 0.24)
                    .position(x: phone.chassis.minX + phone.metalWidth * 0.48,
                              y: min(proxy.size.height * 0.68, width * 1.08))
                Rectangle().fill(.white.opacity(0.26))
                    .frame(width: phone.metalWidth, height: 2)
                    .position(x: phone.chassis.minX + phone.metalWidth / 2, y: width * 0.42)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
