import AppKit
import SwiftUI

struct SelectableTerminalTranscriptView: NSViewRepresentable {
    let transcript: String
    let searchQuery: String
    let selectedMatchIndex: Int?
    let controller: TerminalTranscriptController

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .clear
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        controller.bind(
            copySelection: { [weak textView] in
                guard let textView else {
                    return
                }

                let selectedRange = textView.selectedRange()
                if selectedRange.length > 0,
                   let selected = textView.string[safeNSRange: selectedRange],
                   !selected.isEmpty
                {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selected, forType: .string)
                    return
                }

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(textView.string, forType: .string)
            },
            selectAll: { [weak textView] in
                textView?.selectAll(nil)
            },
            scrollToTop: { [weak textView] in
                textView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
            },
            scrollToBottom: { [weak textView] in
                textView?.scrollToEndOfDocument(nil)
            },
            focus: { [weak textView] in
                textView?.window?.makeFirstResponder(textView)
            }
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else {
            return
        }

        let matches = TerminalTranscriptSearchNavigator.matchRanges(in: transcript, query: searchQuery)
        let selectedRange = selectedRange(matches: matches)
        let displayTranscript = transcript

        let previousSignature = context.coordinator.searchSignature
        let currentSignature = Coordinator.SearchSignature(
            query: normalizedSearchQuery,
            selectedMatchIndex: TerminalTranscriptSearchNavigator.normalizedSelection(
                current: selectedMatchIndex,
                matchCount: matches.count
            )
        )

        if context.coordinator.lastRenderedTranscript != displayTranscript || previousSignature != currentSignature {
            textView.textStorage?.setAttributedString(
                makeAttributedTranscript(
                    transcript: displayTranscript,
                    matches: matches,
                    selectedRange: selectedRange
                )
            )
            context.coordinator.lastRenderedTranscript = displayTranscript
            context.coordinator.searchSignature = currentSignature
        }

        if previousSignature != currentSignature, let selectedRange {
            textView.scrollRangeToVisible(selectedRange)
            textView.setSelectedRange(selectedRange)
        } else if context.coordinator.lastRenderedTranscript == displayTranscript, normalizedSearchQuery.isEmpty {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectedRange(matches: [NSRange]) -> NSRange? {
        guard let selectedIndex = TerminalTranscriptSearchNavigator.normalizedSelection(
            current: selectedMatchIndex,
            matchCount: matches.count
        ) else {
            return nil
        }

        return matches[selectedIndex]
    }

    private func makeAttributedTranscript(
        transcript: String,
        matches: [NSRange],
        selectedRange: NSRange?
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: transcript)
        let baseRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(
            [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ],
            range: baseRange
        )

        for match in matches {
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.18),
                range: match
            )
        }

        if let selectedRange {
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor.systemOrange.withAlphaComponent(0.42),
                range: selectedRange
            )
        }

        return attributed
    }

    final class Coordinator {
        struct SearchSignature: Equatable {
            let query: String
            let selectedMatchIndex: Int?
        }

        weak var textView: NSTextView?
        var lastRenderedTranscript = ""
        var searchSignature = SearchSignature(query: "", selectedMatchIndex: nil)
    }
}

struct HistoryAwareTerminalInputField: NSViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let isEnabled: Bool
    let focusToken: Int
    let onSubmit: () -> Void
    let onMoveBackward: () -> Void
    let onMoveForward: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onMoveBackward: onMoveBackward, onMoveForward: onMoveForward)
    }

    func makeNSView(context: Context) -> TerminalCommandTextField {
        let textField = TerminalCommandTextField()
        textField.delegate = context.coordinator
        textField.isBordered = true
        textField.isBezeled = true
        textField.focusRingType = .default
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.isEditable = true
        textField.isSelectable = true
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.onSubmit = context.coordinator.onSubmit
        textField.onMoveBackward = context.coordinator.onMoveBackward
        textField.onMoveForward = context.coordinator.onMoveForward
        context.coordinator.textField = textField
        return textField
    }

    func updateNSView(_ textField: TerminalCommandTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }

        textField.placeholderString = placeholder
        textField.isEnabled = isEnabled

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textField.window?.makeFirstResponder(textField)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onMoveBackward: () -> Void
        let onMoveForward: () -> Void
        weak var textField: TerminalCommandTextField?
        var lastFocusToken = 0

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onMoveBackward: @escaping () -> Void,
            onMoveForward: @escaping () -> Void
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onMoveBackward = onMoveBackward
            self.onMoveForward = onMoveForward
        }

        func controlTextDidChange(_ obj: Notification) {
            text = textField?.stringValue ?? ""
        }
    }
}

final class TerminalCommandTextField: NSTextField {
    var onSubmit: (() -> Void)?
    var onMoveBackward: (() -> Void)?
    var onMoveForward: (() -> Void)?

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        stringValue = stringValue.trimmingCharacters(in: .newlines)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()

        case #selector(NSResponder.moveUp(_:)):
            onMoveBackward?()

        case #selector(NSResponder.moveDown(_:)):
            onMoveForward?()

        default:
            super.doCommand(by: selector)
        }
    }
}

private extension String {
    subscript(safeNSRange range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: self) else {
            return nil
        }
        return String(self[swiftRange])
    }
}
