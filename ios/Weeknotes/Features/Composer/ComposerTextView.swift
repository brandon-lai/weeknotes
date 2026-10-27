import SwiftUI
import UIKit

/// The composer's editor. A UITextView, because dictated text goes in at the cursor
/// (typing and dictating mix) and low-confidence words get a light underline.
@Observable
final class EditorController {
    fileprivate weak var textView: UITextView?
    fileprivate var onChange: ((String) -> Void)?

    /// Inserts at the cursor (or replaces the selection) with a separating space where
    /// needed. Returns the range of the inserted text.
    @discardableResult
    func insertAtCursor(_ text: String) -> NSRange? {
        guard let textView else { return nil }
        let current = textView.text as NSString
        var range = textView.selectedRange
        if range.location == NSNotFound || range.location > current.length { range = NSRange(location: current.length, length: 0) }
        var piece = text
        if range.location > 0 {
            let before = current.substring(with: NSRange(location: range.location - 1, length: 1))
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { piece = " " + piece }
        }
        let after = range.location + range.length < current.length
            ? current.substring(with: NSRange(location: range.location + range.length, length: 1)) : ""
        if !after.isEmpty && !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { piece += " " }
        return replace(range, with: piece)
    }

    @discardableResult
    func replace(_ range: NSRange, with text: String) -> NSRange? {
        guard let textView else { return nil }
        let length = (textView.text as NSString).length
        guard range.location + range.length <= length else { return nil }
        textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: Self.attributes))
        let inserted = NSRange(location: range.location, length: (text as NSString).length)
        textView.selectedRange = NSRange(location: inserted.location + inserted.length, length: 0)
        onChange?(textView.text)
        return inserted
    }

    func text(in range: NSRange) -> String? {
        guard let textView, range.location + range.length <= (textView.text as NSString).length else { return nil }
        return (textView.text as NSString).substring(with: range)
    }

    /// Light underline on words the speech model wasn't sure about, inside `range`.
    func underline(_ words: Set<String>, in range: NSRange) {
        guard let textView, !words.isEmpty else { return }
        let storage = textView.textStorage
        let text = storage.string as NSString
        guard range.location + range.length <= text.length else { return }
        text.enumerateSubstrings(in: range, options: .byWords) { word, wordRange, _, _ in
            guard let word, words.contains(word.lowercased()) else { return }
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: UIColor.tintColor.withAlphaComponent(0.6),
            ], range: wordRange)
        }
    }

    func focus() { textView?.becomeFirstResponder() }
    func dismissKeyboard() { textView?.resignFirstResponder() }

    static var attributes: [NSAttributedString.Key: Any] {
        let font = UIFont.systemFont(ofSize: 19).withDesign(.serif)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
    }
}

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: EditorController
    var placeholder: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.typingAttributes = EditorController.attributes
        view.attributedText = NSAttributedString(string: text, attributes: EditorController.attributes)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "composerText"
        view.accessibilityLabel = "Your update"
        let label = UILabel()
        label.text = placeholder
        label.font = (EditorController.attributes[.font] as? UIFont)
        label.textColor = .placeholderText
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.tag = 99
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor),
        ])
        label.isHidden = !text.isEmpty
        controller.textView = view
        controller.onChange = { newText in
            context.coordinator.parent.text = newText
            label.isHidden = !newText.isEmpty
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            let selection = view.selectedRange
            view.attributedText = NSAttributedString(string: text, attributes: EditorController.attributes)
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
        (view.viewWithTag(99) as? UILabel)?.isHidden = !text.isEmpty
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView.viewWithTag(99) as? UILabel)?.isHidden = !textView.text.isEmpty
            textView.typingAttributes = EditorController.attributes
        }
    }
}

private extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(design) else { return self }
        let scaled = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(descriptor: descriptor, size: pointSize))
        return scaled
    }
}
