// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit

/// Text input for code and argv values where UIKit's typographic rewriting
/// would change the command. The SwiftUI Binding remains the source of truth.
struct StrictASCIITextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        field.borderStyle = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.keyboardType = .asciiCapable
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.accessibilityIdentifier = "xz-shell-working-directory"
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: StrictASCIITextField
        init(_ parent: StrictASCIITextField) { self.parent = parent }
        @objc func textChanged(_ textField: UITextField) {
            let value = textField.text ?? ""
            if parent.text != value { parent.text = value }
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

/// Multiline one-argv-per-line editor with smart punctuation and correction
/// disabled. Newlines are preserved for the xz-shell page's argv splitter.
struct StrictASCIITextView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.keyboardType = .asciiCapable
        view.returnKeyType = .default
        view.isScrollEnabled = true
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "xz-shell-arguments"
        view.accessibilityLabel = "Accelerator arguments, one argument per line"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StrictASCIITextView
        init(_ parent: StrictASCIITextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            let value = textView.text ?? ""
            if parent.text != value { parent.text = value }
        }
    }
}
