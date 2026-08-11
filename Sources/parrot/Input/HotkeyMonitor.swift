import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a configurable global shortcut and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum Event { case pressed, released, cancelRequested, learnCorrectionRequested }
    enum HotkeyError: Error { case tapCreateFailed }

    static let escapeKeyCode: CGKeyCode = 53

    private var shortcut: HotkeyShortcut
    private var learningShortcut: HotkeyShortcut
    private let debug: Bool
    var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var isLearningPressed = false
    private var learningRequestGeneration = 0

    init(
        shortcut: HotkeyShortcut = .fn,
        learningShortcut: HotkeyShortcut = .learnCorrection,
        debug: Bool = false
    ) {
        self.shortcut = shortcut
        self.learningShortcut = learningShortcut
        self.debug = debug
    }

    func setShortcut(_ shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
        isPressed = false
    }

    func setLearningShortcut(_ shortcut: HotkeyShortcut) {
        learningShortcut = shortcut
        isLearningPressed = false
        learningRequestGeneration += 1
    }

    fileprivate var currentShortcut: HotkeyShortcut { shortcut }
    fileprivate var currentLearningShortcut: HotkeyShortcut { learningShortcut }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
        isLearningPressed = false
        learningRequestGeneration += 1
    }

    /// Consume the Learn shortcut before the foreground application receives
    /// it. This matters for shortcuts such as Command-L, which would otherwise
    /// move focus away from the corrected text before Parrot can inspect it.
    func interceptLearning(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown,
           keyCode == learningShortcut.keyCode,
           event.flags.intersection(Self.supportedModifiers) == learningShortcut.modifiers,
           !learningShortcut.isModifierOnly {
            let shouldArm = !isRepeat && !isLearningPressed
            isLearningPressed = true
            if shouldArm { learningRequestGeneration += 1 }
            return true
        }

        if type == .keyUp,
           keyCode == learningShortcut.keyCode,
           isLearningPressed {
            isLearningPressed = false
            scheduleLearningAfterModifierRelease(
                generation: learningRequestGeneration
            )
            return true
        }
        return false
    }

    /// Custom editors are read through a synthetic Command-C. Starting that
    /// copy from the Learn key-down races the user's still-held Control/Option
    /// modifiers, so Chromium receives a modified shortcut and leaves the
    /// selection unreadable. Wait until the complete Learn chord is released.
    private func scheduleLearningAfterModifierRelease(
        generation: Int,
        attempt: Int = 0
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self,
                  generation == self.learningRequestGeneration,
                  !self.isLearningPressed
            else { return }

            let activeModifiers = CGEventSource.flagsState(.combinedSessionState)
                .intersection(Self.supportedModifiers)
            if !activeModifiers.intersection(self.learningShortcut.modifiers).isEmpty,
               attempt < 150 {
                self.scheduleLearningAfterModifierRelease(
                    generation: generation,
                    attempt: attempt + 1
                )
                return
            }
            self.onEvent?(.learnCorrectionRequested)
        }
    }

    fileprivate func reenableTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // Escape is a global recording cancel independent of the configured
        // dictation shortcut. Only emit on the initial key-down edge.
        if Self.isCancelEvent(type: type, keyCode: keyCode, isRepeat: isRepeat) {
            onEvent?(.cancelRequested)
            return
        }

        if shortcut.isModifierOnly {
            guard type == .flagsChanged, keyCode == shortcut.keyCode else { return }
            let pressed = event.flags.intersection(Self.supportedModifiers)
                == shortcut.modifiers
            guard pressed != isPressed else { return }
            isPressed = pressed
            onEvent?(pressed ? .pressed : .released)
            return
        }

        guard keyCode == shortcut.keyCode else { return }
        switch type {
        case .keyDown:
            guard !isRepeat,
                  !isPressed,
                  event.flags.intersection(Self.supportedModifiers) == shortcut.modifiers
            else { return }
            isPressed = true
            onEvent?(.pressed)
        case .keyUp:
            guard isPressed else { return }
            isPressed = false
            onEvent?(.released)
        default:
            break
        }
    }

    /// The event tap sees the entire keyboard stream. Filter it before the
    /// callback schedules work on the main run loop; otherwise ordinary typing
    /// creates one queued main-queue block per key-down and key-up.
    static func isRelevantEvent(
        type: CGEventType,
        keyCode: CGKeyCode,
        shortcut: HotkeyShortcut,
        learningShortcut: HotkeyShortcut
    ) -> Bool {
        if type == .keyDown, keyCode == escapeKeyCode {
            return true
        }
        if type == .flagsChanged {
            return shortcut.isModifierOnly && keyCode == shortcut.keyCode
        }
        guard type == .keyDown || type == .keyUp else { return false }
        return keyCode == shortcut.keyCode
            || (!learningShortcut.isModifierOnly && keyCode == learningShortcut.keyCode)
    }

    static func isCancelEvent(
        type: CGEventType,
        keyCode: CGKeyCode,
        isRepeat: Bool
    ) -> Bool {
        type == .keyDown && keyCode == escapeKeyCode && !isRepeat
    }

    static func isLearningEvent(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool,
        shortcut: HotkeyShortcut
    ) -> Bool {
        !shortcut.isModifierOnly
            && type == .keyDown
            && !isRepeat
            && keyCode == shortcut.keyCode
            && flags.intersection(supportedModifiers) == shortcut.modifiers
    }

    static func isParrotGeneratedEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData)
            == TextInjector.generatedEventMarker
    }

    private static let supportedModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
    ]
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    // Delivery uses synthetic Unicode or Command-V events. Never interpret
    // those as a user hotkey, even if the configured shortcut overlaps.
    if HotkeyMonitor.isParrotGeneratedEvent(event) {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    guard HotkeyMonitor.isRelevantEvent(
        type: type,
        keyCode: keyCode,
        shortcut: monitor.currentShortcut,
        learningShortcut: monitor.currentLearningShortcut
    ) else {
        return Unmanaged.passUnretained(event)
    }

    if monitor.interceptLearning(type: type, event: event) {
        return nil
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
