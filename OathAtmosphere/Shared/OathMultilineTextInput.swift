import SwiftUI
import UIKit

/// Native multiline entry using the recipient font and keyboard accessory.
/// The enclosing field supplies padding outside the scrolling text area.
struct OathMultilineTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let title: String
    let identifier: String
    var visibleLines = 4

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> InputView {
        let view = InputView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        // Return inserts a real newline. The shared accessory dismisses input.
        view.returnKeyType = .default
        view.inputAccessoryView = context.coordinator.accessory
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: InputView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.focus.update(focused: focused, enabled: context.environment.isEnabled)
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
        view.placeholder.font = font
        view.placeholder.text = title
        view.accessibilityLabel = title
        view.accessibilityIdentifier = identifier
        let direction: UISemanticContentAttribute = context.environment.oathLanguage.isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        view.semanticContentAttribute = direction
        view.placeholder.semanticContentAttribute = direction
        view.textAlignment = .natural
        coordinator.accessory.toolbar.semanticContentAttribute = direction
        coordinator.accessory.updateAppearance(context.environment.colorScheme == .dark ? .dark : .light)
        coordinator.accessory.toolbar.update(words: [], doneLabel: context.environment.oathLocalizer.text(.done),
            onWord: { _ in }, onDone: { [weak coordinator] in coordinator?.dismissFocus() })
        if view.isEditable != context.environment.isEnabled { view.isEditable = context.environment.isEnabled }
        // Do not replace native marked text while an input method is composing.
        // Explicit Clear also clears composition and the old undo buffer.
        if view.text != text, view.markedTextRange == nil || text.isEmpty {
            if text.isEmpty { view.unmarkText(); view.undoManager?.removeAllActions() }
            view.text = text
        }
        view.placeholder.isHidden = !view.text.isEmpty
        view.wantsFocus = focused && view.isEditable
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InputView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: uiView.height(forLines: visibleLines))
    }

    static func dismantleUIView(_ view: InputView, coordinator: Coordinator) {
        coordinator.focus.invalidate()
        view.delegate = nil
        view.wantsFocus = false
        view.resignFirstResponder()
        view.inputAccessoryView = nil
        coordinator.accessory.toolbar.clear()
    }

    final class InputView: UITextView {
        let placeholder = UILabel()
        var wantsFocus = false { didSet { if wantsFocus != oldValue { synchronizeFocus() } } }
        private var focusScheduled = false

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholder.textColor = .placeholderText
            placeholder.isAccessibilityElement = false
            placeholder.isUserInteractionEnabled = false
            addSubview(placeholder)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func height(forLines lines: Int) -> CGFloat {
            ceil((font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight * CGFloat(max(1, lines)))
                + textContainerInset.top + textContainerInset.bottom
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            placeholder.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
                width: max(0, bounds.width - textContainerInset.left - textContainerInset.right),
                height: (font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight)
        }
        override func didMoveToWindow() { super.didMoveToWindow(); synchronizeFocus() }
        private func synchronizeFocus() {
            guard !focusScheduled else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.window != nil else { return }
                if self.wantsFocus, !self.isFirstResponder {
                    self.inputAccessoryView?.frame.size.width = self.window?.bounds.width ?? self.bounds.width
                    self.inputAccessoryView?.sizeToFit()
                    self.becomeFirstResponder()
                } else if !self.wantsFocus, self.isFirstResponder { self.resignFirstResponder() }
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: OathMultilineTextInput
        var updating = false
        let accessory = OathKeyboardAccessory()
        let focus = OathTextInputFocus()
        init(_ parent: OathMultilineTextInput) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !updating else { return }
            parent.text = textView.text
            (textView as? InputView)?.placeholder.isHidden = !textView.text.isEmpty
        }
        func textViewDidBeginEditing(_ textView: UITextView) { reportFocus(true, from: textView) }
        func textViewDidEndEditing(_ textView: UITextView) { reportFocus(false, from: textView) }
        private func reportFocus(_ value: Bool, from view: UITextView) {
            focus.receive(value) { [weak self, weak view] value in
                guard let self, let view, view.delegate === self,
                      view.isFirstResponder == value, self.parent.focused != value else { return }
                self.parent.focused = value
            }
        }
        func dismissFocus() {
            focus.cancelPending()
            if parent.focused { parent.focused = false }
        }
    }
}
