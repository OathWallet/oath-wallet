import SwiftUI
import OathDatabase

/// Controls can retain a binding while the keyboard and disappearing rows are
/// being torn down. A removed draft is a retired form, not a valid array index.
enum OathHDPathBindings {
    static func draft(_ snapshot: HDAccountPathDraft,
                      in drafts: Binding<[HDAccountPathDraft]>) -> Binding<HDAccountPathDraft> {
        Binding {
            drafts.wrappedValue.first(where: { $0.id == snapshot.id }) ?? snapshot
        } set: { updated, transaction in
            var values = drafts.wrappedValue
            guard updated.id == snapshot.id,
                  let index = values.firstIndex(where: { $0.id == snapshot.id }) else { return }
            values[index] = updated
            drafts.transaction(transaction).wrappedValue = values
        }
        // Missing drafts are expected after import, deletion or lock. Ignore
        // their late UI writes; never reinsert them or log user-entered paths.
    }
}

/// Shared EVM/Solana editor. Only the selected numeric component is a text input;
/// the complete path remains visible, with native number-pad and Stepper editing.
struct OathHDPathEditor: View {
    @Binding var draft: HDAccountPathDraft
    let number: Int
    var focusedPath: FocusState<UUID?>.Binding
    let onRemove: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var selection: Int

    init(draft: Binding<HDAccountPathDraft>, number: Int,
         focusedPath: FocusState<UUID?>.Binding, onRemove: @escaping () -> Void) {
        _draft = draft; self.number = number; self.focusedPath = focusedPath; self.onRemove = onRemove
        _selection = State(initialValue: draft.wrappedValue.family == .solana
            ? min(2, draft.wrappedValue.components.count - 1) : draft.wrappedValue.components.count - 1)
    }

    private var selected: Int { min(selection, draft.components.count - 1) }
    private var component: HDAccountPathDraft.Component { draft.components[selected] }
    private func componentLabel(_ index: Int) -> String {
        // The third BIP44 component is the account. Other custom structures use
        // position labels without claiming a specific derivation convention.
        if index == 2, draft.components.first?.value == 44, draft.components.first?.hardened == true {
            return strings.text(.walletAccount)
        }
        return strings.format(.hdPathComponent, strings.number(index + 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(strings.text(.privateKeyPath) + " " + strings.number(number))
                    .oathFont(.subheadline, weight: .semibold)
                Spacer(minLength: 8)
                Menu {
                    Button {
                        draft.appendComponent(); selection = draft.components.count - 1
                        focusedPath.wrappedValue = draft.id
                    } label: { Label(strings.text(.hdPathAddComponent), systemImage: "plus") }
                    .disabled(draft.components.count >= HDAccountPathDraft.maximumComponents)
                    Button {
                        draft.removeLastComponent(); selection = selected
                    } label: { Label(strings.text(.hdPathRemoveComponent), systemImage: "minus") }
                    .disabled(draft.components.count <= 1)
                    Divider()
                    Button(role: .destructive) {
                        if focusedPath.wrappedValue == draft.id { focusedPath.wrappedValue = nil }
                        onRemove()
                    } label: { Label(strings.text(.delete), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel(strings.text(.privateKeyPath) + " " + strings.number(number))
            }

            OathPathWrapLayout(spacing: 6) {
                Text(verbatim: HDAccountPathDraft.rootComponent).font(.body.monospaced()).padding(.vertical, 10)
                // Capture the component value for lazy/retiring children. An
                // old child must not subscript a shortened live component array.
                ForEach(Array(draft.components.enumerated()), id: \.offset) { index, value in
                    HStack(spacing: 6) {
                        Text(verbatim: "/").foregroundStyle(.secondary)
                        Button {
                            selection = index; focusedPath.wrappedValue = draft.id
                        } label: {
                            Text(value.text)
                                .font(.body.monospaced().weight(index == selected ? .semibold : .regular))
                                .padding(.horizontal, 8).frame(minHeight: 44)
                                .foregroundStyle(index == selected ? Color.accentColor : Color.primary)
                                .background(index == selected ? Color.accentColor.opacity(0.10) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(componentLabel(index))
                        .accessibilityValue(value.text)
                        .accessibilityAddTraits(index == selected ? .isSelected : [])
                        .accessibilityIdentifier("hdPaths.component.\(number).\(index)")
                    }
                }
            }
            .environment(\.layoutDirection, .leftToRight)

            VStack(alignment: .leading, spacing: 8) {
                Text(componentLabel(selected)).oathFont(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    TextField(componentLabel(selected), text: Binding(
                        get: { component.digits }, set: { draft.setDigits($0, at: selected) }))
                        .font(.body.monospaced())
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused(focusedPath, equals: draft.id)
                        .environment(\.layoutDirection, .leftToRight)
                        .padding(12)
                        .background(Color(uiColor: OathSurfaceColors.canvas), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("hdPaths.value.\(number)")
                    Stepper(onIncrement: component.value.map { $0 < HDAccountPathDraft.maximumIndex } == true
                            ? { draft.increment(at: selected) } : nil,
                            onDecrement: component.value.map { $0 > 0 } == true
                            ? { draft.decrement(at: selected) } : nil) {
                        Text(componentLabel(selected))
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel(componentLabel(selected))
                    .accessibilityValue(component.digits)
                    .accessibilityIdentifier("hdPaths.stepper.\(number)")
                }
            }

            if draft.family == .evm {
                Toggle(isOn: Binding(get: { component.hardened }, set: { draft.setHardened($0, at: selected) })) {
                    Text(strings.text(.hdPathHardened) + " (′)").oathFont(.subheadline)
                }
                .accessibilityIdentifier("hdPaths.hardened.\(number)")
            }
        }
        .padding(16)
        .background(Color(uiColor: OathSurfaceColors.field), in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

/// Wrap at path separators instead of truncating long paths or making users
/// horizontally scroll to find the account/index. Supports Dynamic Type.
private struct OathPathWrapLayout: Layout {
    let spacing: CGFloat

    private func arrangement(width: CGFloat, subviews: Subviews) -> (CGSize, [CGRect]) {
        let width = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        return arrangement(width: proposal.width ?? idealWidth, subviews: subviews).0
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).1
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
