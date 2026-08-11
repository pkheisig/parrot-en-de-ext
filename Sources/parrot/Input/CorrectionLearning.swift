import AppKit
import ApplicationServices
import Foundation

enum CorrectionLearningError: LocalizedError {
    case noRecentTranscript
    case expired
    case focusChanged
    case noChanges

    var errorDescription: String? {
        switch self {
        case .noRecentTranscript:
            "No recent Parrot transcript is available to learn from."
        case .expired:
            "The last transcript is too old. Dictate, correct, then learn within five minutes."
        case .focusChanged:
            "Parrot could not read the edited transcript from the original app. Keep that field focused and try Learn again."
        case .noChanges:
            "No learnable spelling change was found."
        }
    }
}

struct EditorTextCapture {
    let selectedText: (pid_t?) -> String?
    let wholeText: (pid_t?) -> String?

    static let live = EditorTextCapture(
        selectedText: { processIdentifier in
            ClipboardTextCapture.selectedText(
                processIdentifier: processIdentifier
            )
        },
        wholeText: { processIdentifier in
            ClipboardTextCapture.wholeFocusedEditorText(
                processIdentifier: processIdentifier
            )
        }
    )
}

@MainActor
final class CorrectionLearningController {
    private struct Session {
        let insertedText: String
        let snapshot: FocusedTextSnapshot?
        let processIdentifier: pid_t?
        let createdAt: Date
    }

    private let lifetime: TimeInterval
    private let editorTextCapture: EditorTextCapture
    private var session: Session?

    init(
        lifetime: TimeInterval = 5 * 60,
        editorTextCapture: EditorTextCapture = .live
    ) {
        self.lifetime = lifetime
        self.editorTextCapture = editorTextCapture
    }

    func remember(
        insertedText: String,
        snapshot: FocusedTextSnapshot?,
        processIdentifier: pid_t? = nil
    ) {
        session = Session(
            insertedText: insertedText,
            snapshot: snapshot,
            processIdentifier: processIdentifier,
            createdAt: Date()
        )
    }

    func clear() {
        session = nil
    }

    func proposals() throws -> [CorrectionProposal] {
        guard let session else { throw CorrectionLearningError.noRecentTranscript }
        guard Date().timeIntervalSince(session.createdAt) <= lifetime else {
            self.session = nil
            throw CorrectionLearningError.expired
        }

        var readEditableText = false
        let corrected = session.snapshot?.correctedInsertedText()
        if let corrected {
            readEditableText = true
            let proposals = CorrectionDiff.proposals(
                original: session.insertedText,
                corrected: corrected
            )
            if !proposals.isEmpty { return proposals }
        }

        if let selected = FocusedTextSnapshot.selectedText(
            processIdentifier: session.processIdentifier
        ) {
            readEditableText = true
            if let proposals = CorrectionDiff.proposalsFromSelection(
                original: session.insertedText,
                selected: selected
            ) {
                return proposals
            }
        }

        // Custom web and Electron editors frequently hide their value and
        // selection from AX. Their native Copy command is considerably more
        // interoperable, so use it without permanently changing the clipboard.
        if let selected = editorTextCapture.selectedText(session.processIdentifier) {
            readEditableText = true
            if let proposals = CorrectionDiff.proposalsFromSelection(
                original: session.insertedText,
                selected: selected
            ) {
                return proposals
            }
        }

        if let fieldText = editorTextCapture.wholeText(session.processIdentifier) {
            readEditableText = true
            if let correctedTranscript = CorrectionDiff.bestCorrectedTranscript(
                in: fieldText,
                for: session.insertedText
            ) {
                let proposals = CorrectionDiff.proposals(
                    original: session.insertedText,
                    corrected: correctedTranscript
                )
                if !proposals.isEmpty { return proposals }
            }
        }
        if readEditableText {
            throw CorrectionLearningError.noChanges
        }
        throw CorrectionLearningError.focusChanged
    }
}

struct FocusedTextSnapshot: Sendable {
    private static let anchorLength = 64

    private let processIdentifier: pid_t
    private let prefix: String
    private let suffix: String
    private let originalLocation: Int

    func belongs(to processIdentifier: pid_t) -> Bool {
        self.processIdentifier == processIdentifier
    }

    static func capture() -> FocusedTextSnapshot? {
        guard let element = focusedElement(),
              let value = stringValue(of: element),
              let selection = selectedRange(of: element)
        else { return nil }

        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        let string = value as NSString
        let location = max(0, min(selection.location, string.length))
        let selectedEnd = max(location, min(location + selection.length, string.length))
        let prefixStart = max(0, location - anchorLength)
        let prefix = string.substring(
            with: NSRange(location: prefixStart, length: location - prefixStart)
        )
        let suffixLength = min(anchorLength, string.length - selectedEnd)
        let suffix = string.substring(
            with: NSRange(location: selectedEnd, length: suffixLength)
        )

        return FocusedTextSnapshot(
            processIdentifier: processIdentifier,
            prefix: prefix,
            suffix: suffix,
            originalLocation: location
        )
    }

    func correctedInsertedText() -> String? {
        guard let focused = Self.focusedElement() else { return nil }
        var currentPID: pid_t = 0
        AXUIElementGetPid(focused, &currentPID)
        guard currentPID == processIdentifier else { return nil }
        return insertedText(in: focused)
    }

    /// Delivery verification follows the application captured at hotkey
    /// release even if global focus moves while transcription is running.
    func deliveredInsertedText() -> String? {
        guard let focused = Self.focusedElement(for: processIdentifier) else { return nil }
        return insertedText(in: focused)
    }

    private func insertedText(in focused: AXUIElement) -> String? {
        guard let value = Self.stringValue(of: focused) else { return nil }

        let string = value as NSString
        let start: Int
        if prefix.isEmpty {
            start = 0
        } else {
            let searchLimit = min(
                string.length,
                max(originalLocation + prefix.utf16.count + 512, prefix.utf16.count)
            )
            let range = string.range(
                of: prefix,
                options: .backwards,
                range: NSRange(location: 0, length: searchLimit)
            )
            guard range.location != NSNotFound else { return nil }
            start = NSMaxRange(range)
        }

        let end: Int
        if suffix.isEmpty {
            if let selection = Self.selectedRange(of: focused),
               selection.location >= start {
                end = min(string.length, selection.location + selection.length)
            } else {
                end = string.length
            }
        } else {
            let range = string.range(
                of: suffix,
                options: [],
                range: NSRange(location: start, length: string.length - start)
            )
            guard range.location != NSNotFound else { return nil }
            end = range.location
        }

        guard end >= start else { return nil }
        return string.substring(with: NSRange(location: start, length: end - start))
    }

    static func selectedText(processIdentifier: pid_t? = nil) -> String? {
        let element = processIdentifier.flatMap(focusedElement(for:))
            ?? (processIdentifier == nil ? focusedElement() : nil)
        guard let element else { return nil }
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &raw
        ) == .success,
           let value = raw as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        guard let value = stringValue(of: element),
              let range = selectedRange(of: element),
              range.length > 0
        else { return nil }
        let string = value as NSString
        guard range.location >= 0, range.location + range.length <= string.length else {
            return nil
        }
        return string.substring(
            with: NSRange(location: range.location, length: range.length)
        )
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success,
              let raw
        else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    /// Resolve the application's own first responder rather than the global
    /// focus. This remains stable if the user changes apps while transcription
    /// is running and lets delivery verification inspect the captured target.
    private static func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success,
              let raw
        else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &raw
        ) == .success
        else { return nil }
        if let string = raw as? String {
            return string
        }
        if let attributed = raw as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &raw
        ) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(
            unsafeBitCast(raw, to: AXValue.self),
            .cfRange,
            &range
        ) else { return nil }
        return range
    }
}

enum CorrectionDiff {
    static func proposals(original: String, corrected: String) -> [CorrectionProposal] {
        let left = tokens(in: original)
        let right = tokens(in: corrected)
        guard !left.isEmpty, !right.isEmpty, left.count <= 300, right.count <= 300 else {
            return []
        }

        var lcs = Array(
            repeating: Array(repeating: 0, count: right.count + 1),
            count: left.count + 1
        )
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                lcs[i][j] = left[i] == right[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var proposals: [CorrectionProposal] = []
        var deleted: [String] = []
        var inserted: [String] = []
        var i = 0
        var j = 0

        func flush() {
            let alias = deleted.joined(separator: " ")
            let canonical = inserted.joined(separator: " ")
            if !alias.isEmpty,
               !canonical.isEmpty,
               alias != canonical,
               alias.count <= 160,
               canonical.count <= 160 {
                proposals.append(CorrectionProposal(alias: alias, canonical: canonical))
            }
            deleted.removeAll(keepingCapacity: true)
            inserted.removeAll(keepingCapacity: true)
        }

        while i < left.count || j < right.count {
            if i < left.count, j < right.count, left[i] == right[j] {
                flush()
                i += 1
                j += 1
            } else if i < left.count,
                      (j == right.count || lcs[i + 1][j] >= lcs[i][j + 1]) {
                deleted.append(left[i])
                i += 1
            } else if j < right.count {
                inserted.append(right[j])
                j += 1
            }
        }
        flush()
        return proposals
    }

    static func bestAlias(in original: String, for canonical: String) -> String? {
        let source = tokens(in: original)
        let target = tokens(in: canonical)
        guard !source.isEmpty, !target.isEmpty else { return nil }
        let targetKey = compactKey(target.joined(separator: " "))
        guard !targetKey.isEmpty else { return nil }

        var best: (value: String, score: Double)?
        let minimumSize = max(1, target.count - 1)
        let maximumSize = min(source.count, target.count + 4)
        for size in minimumSize...maximumSize {
            guard size <= source.count else { continue }
            for start in 0...(source.count - size) {
                let value = source[start..<(start + size)].joined(separator: " ")
                let key = compactKey(value)
                let distance = levenshtein(key, targetKey)
                let score = Double(distance) / Double(max(max(key.count, targetKey.count), 1))
                    + Double(max(0, size - target.count)) * 0.025
                if best == nil || score < best!.score {
                    best = (value, score)
                }
            }
        }
        guard let best, best.score <= 0.60 else { return nil }
        return best.value
    }

    static func proposalsFromSelection(
        original: String,
        selected: String
    ) -> [CorrectionProposal]? {
        let originalCount = tokens(in: original).count
        let selectedCount = tokens(in: selected).count
        guard originalCount > 0, selectedCount > 0 else { return nil }

        // A selection covering most of the transcript is treated as the edited
        // transcript. A short selection is treated as only the corrected term.
        if selectedCount >= max(2, originalCount / 2) {
            let proposals = proposals(original: original, corrected: selected)
            if !proposals.isEmpty { return proposals }
        }
        guard let alias = bestAlias(in: original, for: selected) else { return nil }
        return [CorrectionProposal(alias: alias, canonical: selected)]
    }

    static func bestCorrectedTranscript(
        in fieldText: String,
        for original: String
    ) -> String? {
        let source = tokens(in: fieldText)
        let target = tokens(in: original)
        guard !source.isEmpty,
              !target.isEmpty,
              source.count <= 5_000,
              target.count <= 300
        else { return nil }

        let targetKey = compactKey(target.joined(separator: " "))
        let minimumSize = max(1, target.count - min(8, target.count - 1))
        let maximumSize = min(source.count, target.count + 8)
        var best: (value: String, score: Double)?

        for size in minimumSize...maximumSize {
            guard size <= source.count else { continue }
            for start in 0...(source.count - size) {
                let value = source[start..<(start + size)].joined(separator: " ")
                let key = compactKey(value)
                let distance = levenshtein(key, targetKey)
                let score = Double(distance)
                    / Double(max(max(key.count, targetKey.count), 1))
                    + Double(abs(size - target.count)) * 0.015
                if best == nil || score < best!.score {
                    best = (value, score)
                }
            }
        }
        guard let best, best.score <= 0.45 else { return nil }
        return best.value
    }

    private static func tokens(in text: String) -> [String] {
        // Keep punctuation used inside technical terms (C++, node.js, A/B)
        // while excluding sentence-ending periods from learned aliases.
        let pattern =
            #"[\p{L}\p{N}](?:[\p{L}\p{N}+.#/_'’\-]*[\p{L}\p{N}+#/_'’\-])?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func compactKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func levenshtein(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        var previous = Array(0...b.count)
        for (i, lhs) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, rhs) in b.enumerated() {
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (lhs == rhs ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Reads custom editors through their standard Copy command while preserving
/// the user's clipboard. This avoids depending on app-specific AX text APIs.
enum ClipboardTextCapture {
    static func selectedText(processIdentifier: pid_t? = nil) -> String? {
        capture(selectAll: false, processIdentifier: processIdentifier)
    }

    static func wholeFocusedEditorText(processIdentifier: pid_t? = nil) -> String? {
        capture(selectAll: true, processIdentifier: processIdentifier)
    }

    private static func capture(
        selectAll: Bool,
        processIdentifier: pid_t?
    ) -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        pasteboard.clearContents()
        let sentinel = "parrot-copy-sentinel-\(UUID().uuidString)"
        guard pasteboard.setString(sentinel, forType: .string) else { return nil }
        let sentinelChangeCount = pasteboard.changeCount

        if selectAll {
            postKey(
                0,
                modifiers: .maskCommand,
                processIdentifier: processIdentifier
            ) // Command-A
            Thread.sleep(forTimeInterval: 0.04)
        }
        postKey(
            8,
            modifiers: .maskCommand,
            processIdentifier: processIdentifier
        ) // Command-C

        let deadline = Date().addingTimeInterval(0.35)
        while pasteboard.changeCount == sentinelChangeCount, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let copied = pasteboard.string(forType: .string)
        if selectAll {
            // Do not leave the user's editor with all content selected.
            postKey(
                124,
                modifiers: [],
                processIdentifier: processIdentifier
            ) // Right Arrow, collapse at the end.
            Thread.sleep(forTimeInterval: 0.03)
        }
        guard let copied,
              copied != sentinel,
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              copied.count <= 100_000
        else { return nil }
        return copied
    }

    private static func postKey(
        _ keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        processIdentifier: pid_t?
    ) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        )
        down?.flags = modifiers
        if let processIdentifier {
            down?.postToPid(processIdentifier)
        } else {
            down?.post(tap: .cgSessionEventTap)
        }
        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        )
        up?.flags = modifiers
        if let processIdentifier {
            up?.postToPid(processIdentifier)
        } else {
            up?.post(tap: .cgSessionEventTap)
        }
    }
}

struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    @discardableResult
    func restore(
        to pasteboard: NSPasteboard,
        ifUnchangedSince expectedChangeCount: Int? = nil,
        orStillContaining expectedString: String? = nil
    ) -> Bool {
        if let expectedChangeCount,
           pasteboard.changeCount != expectedChangeCount {
            guard let expectedString,
                  pasteboard.string(forType: .string)?
                    .precomposedStringWithCanonicalMapping
                    == expectedString.precomposedStringWithCanonicalMapping
            else { return false }
        }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let restored = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
        return true
    }
}
