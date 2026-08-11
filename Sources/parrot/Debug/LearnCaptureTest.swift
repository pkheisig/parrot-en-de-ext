import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

/// Internal probe for exercising the exact clipboard paths used by Learn in
/// Accessibility-opaque editors without rebuilding or launching Parrot.app.
struct LearnCaptureTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "learn-capture-test",
        abstract: "Probe Learn text capture in the focused editor.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: "Post Copy events globally like the legacy path.")
    var globalEvents = false

    @Option(name: .long, help: "Original transcript to compare with captured editor text.")
    var original: String?

    @Option(name: .long, help: "Target process id instead of the frontmost application.")
    var pid: Int32?

    @Option(name: .long, help: "Wait before probing so the target editor can be focused.")
    var delay: Double = 0

    mutating func run() throws {
        if delay > 0 {
            Thread.sleep(forTimeInterval: min(delay, 30))
        }
        let target = pid.flatMap(NSRunningApplication.init(processIdentifier:))
            ?? NSWorkspace.shared.frontmostApplication
        let useGlobalEvents = globalEvents
        let processIdentifier = useGlobalEvents ? nil : target?.processIdentifier
        let original = self.original
        Task { @MainActor in
            var selected: String?
            var whole: String?
            let capture = EditorTextCapture(
                selectedText: { pid in
                    selected = ClipboardTextCapture.selectedText(
                        processIdentifier: pid
                    )
                    return selected
                },
                wholeText: { pid in
                    whole = ClipboardTextCapture.wholeFocusedEditorText(
                        processIdentifier: pid
                    )
                    return whole
                }
            )
            let controller = CorrectionLearningController(
                editorTextCapture: capture
            )

            var proposals: [CorrectionProposal] = []
            var learningError: Error?
            if let original {
                controller.remember(
                    insertedText: original,
                    snapshot: nil,
                    processIdentifier: processIdentifier
                )
                do {
                    proposals = try controller.proposals()
                } catch {
                    learningError = error
                }
            } else {
                selected = ClipboardTextCapture.selectedText(
                    processIdentifier: processIdentifier
                )
                whole = ClipboardTextCapture.wholeFocusedEditorText(
                    processIdentifier: processIdentifier
                )
            }

            print(
                "target=\(target?.localizedName ?? "none")"
                    + "[\(target?.processIdentifier ?? 0)]"
                    + " events=\(useGlobalEvents ? "global" : "targeted")"
            )
            print("accessibility_trusted=\(AXIsProcessTrusted())")
            Self.printCapture("selected", selected)
            Self.printCapture("whole", whole)
            for proposal in proposals {
                print("proposal=\(proposal.alias) -> \(proposal.canonical)")
            }
            if let learningError {
                print("learning_error=\(learningError.localizedDescription)")
            }
            Darwin.exit(EXIT_SUCCESS)
        }
        dispatchMain()
    }

    private static func printCapture(_ label: String, _ value: String?) {
        guard let value else {
            print("\(label)=unreadable")
            return
        }
        let preview = value
            .prefix(160)
            .replacingOccurrences(of: "\n", with: "\\n")
        print("\(label)=read length=\(value.count) preview=\(preview)")
    }
}
