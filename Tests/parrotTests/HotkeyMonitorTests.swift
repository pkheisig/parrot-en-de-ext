import CoreGraphics
import XCTest
@testable import parrot

final class HotkeyMonitorTests: XCTestCase {
    func testEscapeInitialKeyDownRequestsCancellation() {
        XCTAssertTrue(
            HotkeyMonitor.isCancelEvent(
                type: .keyDown,
                keyCode: HotkeyMonitor.escapeKeyCode,
                isRepeat: false
            )
        )
    }

    func testEscapeReleaseAndRepeatDoNotRequestCancellation() {
        XCTAssertFalse(
            HotkeyMonitor.isCancelEvent(
                type: .keyUp,
                keyCode: HotkeyMonitor.escapeKeyCode,
                isRepeat: false
            )
        )
        XCTAssertFalse(
            HotkeyMonitor.isCancelEvent(
                type: .keyDown,
                keyCode: HotkeyMonitor.escapeKeyCode,
                isRepeat: true
            )
        )
    }

    func testOtherKeysDoNotRequestCancellation() {
        XCTAssertFalse(
            HotkeyMonitor.isCancelEvent(
                type: .keyDown,
                keyCode: 49,
                isRepeat: false
            )
        )
    }

    func testUnrelatedKeyboardEventsAreFilteredBeforeMainQueueDispatch() {
        XCTAssertFalse(
            HotkeyMonitor.isRelevantEvent(
                type: .keyDown,
                keyCode: 0,
                shortcut: .fn,
                learningShortcut: .learnCorrection
            )
        )
        XCTAssertFalse(
            HotkeyMonitor.isRelevantEvent(
                type: .keyUp,
                keyCode: 49,
                shortcut: .fn,
                learningShortcut: .learnCorrection
            )
        )
        XCTAssertTrue(
            HotkeyMonitor.isRelevantEvent(
                type: .flagsChanged,
                keyCode: HotkeyShortcut.fn.keyCode,
                shortcut: .fn,
                learningShortcut: .learnCorrection
            )
        )
        XCTAssertTrue(
            HotkeyMonitor.isRelevantEvent(
                type: .keyDown,
                keyCode: HotkeyMonitor.escapeKeyCode,
                shortcut: .fn,
                learningShortcut: .learnCorrection
            )
        )
    }

    func testLearningShortcutRequiresExactModifiersAndInitialKeyDown() {
        let shortcut = HotkeyShortcut.learnCorrection
        XCTAssertTrue(
            HotkeyMonitor.isLearningEvent(
                type: .keyDown,
                keyCode: 37,
                flags: [.maskControl, .maskAlternate],
                isRepeat: false,
                shortcut: shortcut
            )
        )
        XCTAssertFalse(
            HotkeyMonitor.isLearningEvent(
                type: .keyDown,
                keyCode: 37,
                flags: [.maskControl, .maskAlternate, .maskShift],
                isRepeat: false,
                shortcut: shortcut
            )
        )
        XCTAssertFalse(
            HotkeyMonitor.isLearningEvent(
                type: .keyDown,
                keyCode: 37,
                flags: [.maskControl, .maskAlternate],
                isRepeat: true,
                shortcut: shortcut
            )
        )
    }

    func testLearningShortcutIsConsumedThroughKeyUp() throws {
        let shortcut = HotkeyShortcut(
            keyCode: 37,
            modifiersRawValue: CGEventFlags.maskCommand.rawValue,
            isModifierOnly: false
        )
        let monitor = HotkeyMonitor(learningShortcut: shortcut)
        let emitted = expectation(description: "learn event emitted after key release")
        var emissionCount = 0
        monitor.onEvent = { event in
            if case .learnCorrectionRequested = event {
                emissionCount += 1
                emitted.fulfill()
            }
        }
        let down = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: true)
        )
        down.flags = .maskCommand
        XCTAssertTrue(monitor.interceptLearning(type: .keyDown, event: down))
        XCTAssertEqual(emissionCount, 0)

        let up = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: false)
        )
        up.flags = .maskCommand
        XCTAssertTrue(monitor.interceptLearning(type: .keyUp, event: up))
        wait(for: [emitted], timeout: 0.5)
        XCTAssertEqual(emissionCount, 1)

        let wrongModifiers = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: true)
        )
        wrongModifiers.flags = [.maskCommand, .maskShift]
        XCTAssertFalse(
            monitor.interceptLearning(type: .keyDown, event: wrongModifiers)
        )
    }

    func testGeneratedDeliveryEventsCannotRetriggerHotkeys() throws {
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
        )
        XCTAssertFalse(HotkeyMonitor.isParrotGeneratedEvent(event))
        event.setIntegerValueField(
            .eventSourceUserData,
            value: TextInjector.generatedEventMarker
        )
        XCTAssertTrue(HotkeyMonitor.isParrotGeneratedEvent(event))
    }
}
