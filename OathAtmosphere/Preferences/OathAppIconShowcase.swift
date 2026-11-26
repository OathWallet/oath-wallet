import SwiftUI

struct OathIconShowcaseChoice: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let useTitle: String
    let image: Image
}

/// Presentation only. The containing page owns the system icon request and its
/// shared diagnostics boundary; browsing never installs an icon.
struct OathAppIconShowcase: View {
    @Environment(\.oathLocalizer) private var strings
    let choices: [OathIconShowcaseChoice]
    @Binding var focusedID: String?
    let installedID: String?
    let changing: Bool
    let available: Bool
    let title: String
    let selectedTitle: String
    let unavailableTitle: String
    let onApply: (String) -> Void
    let onBrowse: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var focused: OathIconShowcaseChoice? {
        choices.first { $0.id == focusedID } ?? choices.first
    }

    var body: some View {
        GeometryReader { geometry in
            if let focused {
                Group {
                    if dynamicTypeSize.isAccessibilitySize || geometry.size.height < 560 {
                        ScrollView {
                            layout(focused, width: geometry.size.width, topInset: geometry.safeAreaInsets.top, stageHeight: max(230, geometry.size.height * 0.48))
                        }
                        .scrollIndicators(.hidden)
                    } else {
                        layout(focused, width: geometry.size.width, topInset: geometry.safeAreaInsets.top)
                    }
                }
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .foregroundStyle(.primary)
        .onChange(of: focusedID) { old, new in
            if old != nil, new != nil, old != new { onBrowse() }
        }
    }

    private func layout(_ choice: OathIconShowcaseChoice, width: CGFloat, topInset: CGFloat, stageHeight: CGFloat? = nil) -> some View {
        VStack(spacing: 0) {
            stage(width: width, topInset: topInset)
                .frame(minHeight: 170, maxHeight: .infinity)
                .frame(height: stageHeight)
            details(choice).padding(.horizontal, 24)
            action(choice)
                .padding(.horizontal, 24)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 20 : 62)
                .padding(.bottom, 16)
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: installedID)
        }
    }

    private func stage(width: CGFloat, topInset: CGFloat) -> some View {
        GeometryReader { geometry in
            let iconSize = min(132.0, max(92.0, width * 0.30))
            let stride = iconSize + 38
            let motion = !reduceMotion
            let canvasHeight = geometry.size.height + topInset
            ZStack {
                OathIconPhoneFrame(background: Color(uiColor: OathSurfaceColors.canvas))
                    .mask { LinearGradient(stops: [.init(color: .white, location: 0),
                        .init(color: .white, location: 0.76), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom) }
                    .accessibilityHidden(true)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 38) {
                        ForEach(choices) { choice in
                            OathButton(feedback: nil) { focus(choice.id) } label: {
                                VStack(spacing: 9) {
                                    choice.image.resizable().interpolation(.high).scaledToFit()
                                        .frame(width: iconSize, height: iconSize)
                                        .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.225, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: iconSize * 0.225, style: .continuous)
                                                .strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                                        }
                                        .shadow(color: .black.opacity(0.6), radius: 12, y: 10)
                                    Text(verbatim: strings.appDisplayName)
                                        .oathFont(.caption, weight: .medium)
                                        .lineLimit(1)
                                }
                                .frame(width: iconSize)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(changing)
                            .accessibilityIdentifier("preferences.appIcon.\(choice.id)")
                            .visualEffect { content, proxy in
                                // Scroll coordinates exclude the centering margins.
                                let viewport = proxy.bounds(of: .scrollView(axis: .horizontal))?.width ?? iconSize
                                let distance = (proxy.frame(in: .scrollView(axis: .horizontal)).midX - viewport / 2) / stride
                                let amount: CGFloat = min(1, abs(distance))
                                let scale: CGFloat = motion ? 1 - amount * 0.14 : 1
                                let angle = Angle.degrees(motion ? Double(distance) * -12 : 0)
                                let radius: CGFloat = motion ? amount * 1.1 : 0
                                let opacity = Double(1 - amount * 0.2)
                                return content.scaleEffect(scale)
                                    .rotation3DEffect(angle, axis: (x: 0, y: 1, z: 0), perspective: 0.32)
                                    .blur(radius: radius).opacity(opacity)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 28)
                }
                .contentMargins(.horizontal, (width - iconSize) / 2, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
                .scrollPosition(id: $focusedID)
                .scrollIndicators(.hidden)
                .scrollDisabled(changing)
                .frame(height: iconSize + 90)
                .mask { LinearGradient(stops: [.init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.10), .init(color: .white, location: 0.18),
                    .init(color: .white, location: 0.88),
                    .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing) }
                .position(x: width / 2, y: topInset + geometry.size.height * 0.48)
                // Clip after perspective, blur and shadows, in the same coordinate
                // space as the bezel. Nothing can draw over the phone hardware.
                .clipShape(OathIconPhoneDisplay())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(focused?.title ?? "")
                .accessibilityAdjustableAction { direction in
                    guard !changing, let current = choices.firstIndex(where: { $0.id == focused?.id }) else { return }
                    let next: Int
                    switch direction {
                    case .increment: next = min(choices.count - 1, current + 1)
                    case .decrement: next = max(0, current - 1)
                    @unknown default: return
                    }
                    focus(choices[next].id)
                }
                .accessibilityIdentifier("preferences.appIcon.carousel")
            }
            // Only the artwork extends under the native bar; the carousel center
            // and footer still use the unobstructed content area.
            .frame(width: width, height: canvasHeight)
            .offset(y: -topInset)
        }
    }

    private func details(_ choice: OathIconShowcaseChoice) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(choices) { item in
                    Capsule().fill(.white.opacity(item.id == choice.id ? 1 : 0.34))
                        .frame(width: item.id == choice.id ? 17 : 4, height: 4)
                }
            }
            .frame(height: 12)
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: choice.id)
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(verbatim: choice.title)
                    .oathFont(.largeTitle, weight: .bold)
                    .minimumScaleFactor(0.7)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: choice.subtitle)
                    .oathFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(choice.id)
            .transition(.blurReplace)
            .padding(.top, 14)
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: choice.id)
            Group {
                if installedID == choice.id {
                    HStack(spacing: 5) {
                        Circle().fill(.white).frame(width: 5, height: 5)
                        Text(verbatim: selectedTitle).oathFont(.caption, weight: .semibold)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(uiColor: OathSurfaceColors.card), in: Capsule())
                    .accessibilityIdentifier("preferences.appIcon.installed")
                } else { Color.clear.frame(height: 27).accessibilityHidden(true) }
            }
            .padding(.top, 11)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: installedID)
    }

    @ViewBuilder private func action(_ choice: OathIconShowcaseChoice) -> some View {
        if !available {
            Text(verbatim: unavailableTitle).oathFont(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(minHeight: 54)
        } else {
            OathActionButton(title: choice.useTitle, isWorking: changing, isInteractionBlocked: changing) {
                onApply(choice.id)
            }
            .oathActionArea(existingInset: 24)
            .disabled(changing || installedID == choice.id)
            // Measure the shared button even for the installed icon so the
            // carousel and caption stay still when the selected badge appears.
            .opacity(installedID == choice.id ? 0 : 1)
            .accessibilityHidden(installedID == choice.id)
            .accessibilityIdentifier("preferences.appIcon.apply")
        }
    }

    private func focus(_ id: String) {
        guard !changing else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.14)) { focusedID = id }
    }
}
