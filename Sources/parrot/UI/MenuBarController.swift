import AppKit
import CoreGraphics

/// Compact settings popover anchored to the menu-bar icon.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let statusItemAutosaveName = AppIdentity.statusItemAutosaveName

    var onShortcutChanged: ((HotkeyShortcut) -> Void)?
    var onLearningShortcutChanged: ((HotkeyShortcut) -> Void)?
    var onActivationModeChanged: ((ActivationMode) -> Void)?
    var onLanguageChanged: ((TranscriptionLanguage) -> Void)?
    var onModelPreferenceChanged: ((TranscriptionModelPreference) -> Void)?

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let settings: DictationSettings
    private let dictionary: CorrectionDictionaryStore
    private let contentController: SettingsViewController
    private var dictionaryWindow: DictionaryWindowController?

    init(
        modelID: String,
        settings: DictationSettings,
        dictionary: CorrectionDictionaryStore
    ) {
        self.settings = settings
        self.dictionary = dictionary
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.contentController = SettingsViewController(
            modelID: modelID,
            shortcut: settings.shortcut,
            learningShortcut: settings.learningShortcut,
            activationMode: settings.activationMode,
            language: settings.transcriptionLanguage,
            modelPreference: settings.transcriptionModelPreference,
            dictionaryCount: dictionary.entries.count
        )
        super.init()

        // A stable autosave identity prevents AppKit from manufacturing a new
        // status-item identity after each ad-hoc rebuild. The item is the app's
        // only settings surface, so it is intentionally not user-removable.
        statusItem.autosaveName = Self.statusItemAutosaveName
        statusItem.behavior = []
        statusItem.isVisible = true

        contentController.onShortcutChanged = { [weak self] shortcut in
            guard let self else { return }
            guard shortcut != self.settings.learningShortcut else {
                self.contentController.setShortcut(self.settings.shortcut)
                self.contentController.setState("dictation and learn hotkeys must differ")
                NSSound.beep()
                return
            }
            self.settings.shortcut = shortcut
            self.onShortcutChanged?(shortcut)
            self.contentController.setState(self.idleText)
        }
        contentController.onActivationModeChanged = { [weak self] mode in
            self?.settings.activationMode = mode
            self?.onActivationModeChanged?(mode)
            if let self {
                self.contentController.setState(self.idleText)
            }
        }
        contentController.onLanguageChanged = { [weak self] language in
            guard let self else { return }
            // Persist the requested language before its model finishes loading.
            // Large specialists can take time to download on first selection;
            // quitting during that load must not silently restore Automatic.
            self.settings.transcriptionLanguage = language
            self.onLanguageChanged?(language)
        }
        contentController.onModelPreferenceChanged = { [weak self] preference in
            guard let self else { return }
            self.settings.transcriptionModelPreference = preference
            self.onModelPreferenceChanged?(preference)
        }
        contentController.onLearningShortcutChanged = { [weak self] shortcut in
            guard let self else { return }
            guard shortcut != self.settings.shortcut else {
                self.contentController.setLearningShortcut(self.settings.learningShortcut)
                self.contentController.setState("dictation and learn hotkeys must differ")
                NSSound.beep()
                return
            }
            self.settings.learningShortcut = shortcut
            self.onLearningShortcutChanged?(shortcut)
        }
        contentController.onOpenDictionary = { [weak self] in
            self?.showDictionary()
        }
        contentController.onQuit = {
            NSApp.terminate(nil)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.contentViewController = contentController
        popover.delegate = self

        if let button = statusItem.button {
            let image = Self.birdImage()
                ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Parrot")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Parrot settings"
        }
        FileHandle.standardError.write(Data(
            "menu-bar item ready · \(Self.statusItemAutosaveName)\n".utf8
        ))
    }

    func setRecording(_ recording: Bool) {
        contentController.setState(recording ? "● recording" : idleText)
        statusItem.button?.appearsDisabled = false
    }

    func setTranscribing() {
        contentController.setState("transcribing…")
    }

    func setCopiedToClipboard() {
        contentController.setState("copied to clipboard")
    }

    func setDeliveryFailure() {
        contentController.setState("couldn’t deliver transcript")
    }

    func setUnavailable(_ message: String) {
        contentController.setState(message)
    }

    func setLearningStatus(_ message: String) {
        contentController.setState(message)
    }

    func showLearningError(_ message: String) {
        contentController.setState(message)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn’t learn correction"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @discardableResult
    func confirmCorrections(_ proposals: [CorrectionProposal]) -> Int {
        var learned = 0
        NSApp.activate(ignoringOtherApps: true)
        for proposal in proposals {
            let fields = CorrectionFieldsView(
                alias: proposal.alias,
                canonical: proposal.canonical
            )
            let alert = NSAlert()
            alert.messageText = "Learn correction?"
            alert.informativeText =
                "Parrot will bias future dictation toward the corrected spelling."
            alert.alertStyle = .informational
            alert.accessoryView = fields
            alert.addButton(withTitle: "Learn")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { break }
            if dictionary.upsert(
                alias: fields.aliasField.stringValue,
                canonical: fields.canonicalField.stringValue
            ) != nil {
                learned += 1
            } else {
                NSSound.beep()
            }
        }
        contentController.setDictionaryCount(dictionary.entries.count)
        return learned
    }

    func setLoading(_ language: TranscriptionLanguage) {
        contentController.setConfigurationEnabled(false, language: language)
        contentController.setState("loading \(language.displayName.lowercased()) model…")
    }

    func setReady(
        modelID: String,
        language: TranscriptionLanguage,
        modelPreference: TranscriptionModelPreference
    ) {
        settings.transcriptionLanguage = language
        settings.transcriptionModelPreference = modelPreference
        contentController.setConfigurationEnabled(true, language: language)
        contentController.setLanguage(language)
        contentController.setModelPreference(modelPreference)
        contentController.setModel(modelID)
        contentController.setState(idleText)
    }

    func setLanguageError(_ message: String) {
        contentController.setConfigurationEnabled(
            true,
            language: settings.transcriptionLanguage
        )
        contentController.setLanguage(settings.transcriptionLanguage)
        contentController.setModelPreference(settings.transcriptionModelPreference)
        contentController.setState(message)
    }

    private var idleText: String {
        let verb = settings.activationMode == .hold ? "hold" : "press"
        return "idle · \(verb) \(settings.shortcut.displayName.lowercased()) to dictate"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            contentController.setState(idleText)
            contentController.setDictionaryCount(dictionary.entries.count)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showDictionary() {
        popover.performClose(nil)
        if dictionaryWindow == nil {
            dictionaryWindow = DictionaryWindowController(store: dictionary)
        }
        dictionaryWindow?.showWindow(nil)
        dictionaryWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

@MainActor
private final class SettingsViewController: NSViewController {
    var onShortcutChanged: ((HotkeyShortcut) -> Void)?
    var onLearningShortcutChanged: ((HotkeyShortcut) -> Void)?
    var onActivationModeChanged: ((ActivationMode) -> Void)?
    var onLanguageChanged: ((TranscriptionLanguage) -> Void)?
    var onModelPreferenceChanged: ((TranscriptionModelPreference) -> Void)?
    var onOpenDictionary: (() -> Void)?
    var onQuit: (() -> Void)?

    private let stateLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let shortcutButton = ShortcutRecorderButton()
    private let learningShortcutButton = ShortcutRecorderButton()
    private let dictionaryButton = NSButton()
    private let modeControl = NSSegmentedControl(
        labels: ActivationMode.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let launchAtLogin = LaunchAtLoginManager()
    private let loginCheckbox = NSButton()
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()

    init(
        modelID: String,
        shortcut: HotkeyShortcut,
        learningShortcut: HotkeyShortcut,
        activationMode: ActivationMode,
        language: TranscriptionLanguage,
        modelPreference: TranscriptionModelPreference,
        dictionaryCount: Int
    ) {
        super.init(nibName: nil, bundle: nil)

        let title = NSTextField(labelWithString: "Parrot")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = .secondaryLabelColor

        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .tertiaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingMiddle
        setModel(modelID)

        shortcutButton.shortcut = shortcut
        shortcutButton.toolTip = "Click, then press a shortcut. Modifier-only keys are supported."
        shortcutButton.onShortcutChanged = { [weak self] shortcut in
            self?.onShortcutChanged?(shortcut)
        }

        learningShortcutButton.shortcut = learningShortcut
        learningShortcutButton.allowsModifierOnly = false
        learningShortcutButton.toolTip = "After editing the last transcript, press this to learn the correction."
        learningShortcutButton.onShortcutChanged = { [weak self] shortcut in
            self?.onLearningShortcutChanged?(shortcut)
        }

        modeControl.selectedSegment = ActivationMode.allCases.firstIndex(of: activationMode) ?? 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        let shortcutRow = Self.row(label: "Hotkey", control: shortcutButton)
        let learningRow = Self.row(label: "Learn", control: learningShortcutButton)
        let modeRow = Self.row(label: "Behavior", control: modeControl)

        languagePopup.addItems(withTitles: TranscriptionLanguage.allCases.map(\.displayName))
        languagePopup.selectItem(at: TranscriptionLanguage.allCases.firstIndex(of: language) ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        let languageRow = Self.row(label: "Language", control: languagePopup)

        modelPopup.addItems(
            withTitles: TranscriptionModelPreference.allCases.map(\.displayName)
        )
        setModelPreference(modelPreference)
        modelPopup.isEnabled = language != .german
        modelPopup.target = self
        modelPopup.action = #selector(modelPreferenceChanged)
        let modelRow = Self.row(label: "Model", control: modelPopup)

        dictionaryButton.bezelStyle = .rounded
        dictionaryButton.target = self
        dictionaryButton.action = #selector(openDictionary)
        setDictionaryCount(dictionaryCount)
        let dictionaryRow = Self.row(label: "Words", control: dictionaryButton)

        loginCheckbox.setButtonType(.switch)
        loginCheckbox.title = "Launch Parrot at login"
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginSettingChanged)
        loginCheckbox.state = launchAtLogin.isRegistered ? .on : .off
        loginCheckbox.isEnabled = launchAtLogin.isAvailable

        loginStatusLabel.font = .systemFont(ofSize: 10)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.maximumNumberOfLines = 2
        loginStatusLabel.lineBreakMode = .byWordWrapping
        refreshLoginStatus()

        let loginControl = NSStackView(views: [loginCheckbox, loginStatusLabel])
        loginControl.orientation = .vertical
        loginControl.alignment = .leading
        loginControl.spacing = 3
        let loginRow = Self.row(label: "Startup", control: loginControl)

        let separator = NSBox()
        separator.boxType = .separator

        let quitButton = NSButton(title: "Quit Parrot", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .inline
        quitButton.alignment = .left
        quitButton.contentTintColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            title, stateLabel, modelLabel, shortcutRow, learningRow, modeRow,
            languageRow, modelRow, dictionaryRow, loginRow, separator, quitButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(2, after: stateLabel)
        stack.setCustomSpacing(14, after: modelLabel)
        stack.setCustomSpacing(12, after: loginRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.addSubview(stack)
        view = container

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
            shortcutRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            learningRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            languageRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dictionaryRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setState(_ text: String) {
        stateLabel.stringValue = text
    }

    func setModel(_ modelID: String) {
        modelLabel.stringValue = "model: \(modelID)"
    }

    func setLanguage(_ language: TranscriptionLanguage) {
        languagePopup.selectItem(
            at: TranscriptionLanguage.allCases.firstIndex(of: language) ?? 0
        )
    }

    func setModelPreference(_ preference: TranscriptionModelPreference) {
        modelPopup.selectItem(
            at: TranscriptionModelPreference.allCases.firstIndex(of: preference) ?? 0
        )
    }

    func setConfigurationEnabled(
        _ enabled: Bool,
        language: TranscriptionLanguage
    ) {
        languagePopup.isEnabled = enabled
        modelPopup.isEnabled = enabled && language != .german
    }

    func setShortcut(_ shortcut: HotkeyShortcut) {
        shortcutButton.shortcut = shortcut
    }

    func setLearningShortcut(_ shortcut: HotkeyShortcut) {
        learningShortcutButton.shortcut = shortcut
    }

    func setDictionaryCount(_ count: Int) {
        dictionaryButton.title = count == 1
            ? "Dictionary… (1 correction)"
            : "Dictionary… (\(count) corrections)"
    }

    private static func row(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12)
        labelView.textColor = .secondaryLabelColor
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelView.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func modeChanged() {
        let modes = ActivationMode.allCases
        guard modes.indices.contains(modeControl.selectedSegment) else { return }
        onActivationModeChanged?(modes[modeControl.selectedSegment])
    }

    @objc private func languageChanged() {
        let languages = TranscriptionLanguage.allCases
        guard languages.indices.contains(languagePopup.indexOfSelectedItem) else { return }
        onLanguageChanged?(languages[languagePopup.indexOfSelectedItem])
    }

    @objc private func modelPreferenceChanged() {
        let preferences = TranscriptionModelPreference.allCases
        guard preferences.indices.contains(modelPopup.indexOfSelectedItem) else { return }
        onModelPreferenceChanged?(preferences[modelPopup.indexOfSelectedItem])
    }

    @objc private func openDictionary() {
        onOpenDictionary?()
    }

    @objc private func loginSettingChanged() {
        let requested = loginCheckbox.state == .on
        do {
            try launchAtLogin.setRegistered(requested)
        } catch {
            loginCheckbox.state = launchAtLogin.isRegistered ? .on : .off
            loginStatusLabel.textColor = .systemRed
            loginStatusLabel.stringValue = error.localizedDescription
            return
        }
        loginCheckbox.state = launchAtLogin.isRegistered ? .on : .off
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.stringValue = launchAtLogin.statusMessage ?? ""
        loginStatusLabel.isHidden = loginStatusLabel.stringValue.isEmpty
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}

@MainActor
private final class ShortcutRecorderButton: NSButton {
    var onShortcutChanged: ((HotkeyShortcut) -> Void)?
    var allowsModifierOnly = true
    var shortcut: HotkeyShortcut = .fn {
        didSet { title = shortcut.displayName }
    }

    private var isRecordingShortcut = false
    private var pendingModifier: (keyCode: CGKeyCode, flags: CGEventFlags)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func beginRecording() {
        isRecordingShortcut = true
        pendingModifier = nil
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        let modifiers = Self.cgModifiers(from: event.modifierFlags)
        let functionKey = (96...126).contains(event.keyCode)
        guard !modifiers.isEmpty || functionKey else {
            NSSound.beep()
            title = "Add a modifier"
            return
        }

        commit(HotkeyShortcut(
            keyCode: CGKeyCode(event.keyCode),
            modifiersRawValue: modifiers.rawValue,
            isModifierOnly: false
        ))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecordingShortcut else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard allowsModifierOnly,
              isRecordingShortcut,
              let flag = Self.flag(forModifierKeyCode: event.keyCode)
        else {
            super.flagsChanged(with: event)
            return
        }

        let flags = Self.cgModifiers(from: event.modifierFlags)
        if flags.contains(flag) {
            pendingModifier = (CGKeyCode(event.keyCode), flag)
            title = HotkeyShortcut(
                keyCode: CGKeyCode(event.keyCode),
                modifiersRawValue: flag.rawValue,
                isModifierOnly: true
            ).displayName
        } else if let pendingModifier {
            commit(HotkeyShortcut(
                keyCode: pendingModifier.keyCode,
                modifiersRawValue: pendingModifier.flags.rawValue,
                isModifierOnly: true
            ))
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecordingShortcut {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }

    private func commit(_ shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
        isRecordingShortcut = false
        pendingModifier = nil
        onShortcutChanged?(shortcut)
        window?.makeFirstResponder(nil)
    }

    private func cancelRecording() {
        isRecordingShortcut = false
        pendingModifier = nil
        title = shortcut.displayName
        window?.makeFirstResponder(nil)
    }

    private static func cgModifiers(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }

    private static func flag(forModifierKeyCode keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: .maskCommand
        case 56, 60: .maskShift
        case 58, 61: .maskAlternate
        case 59, 62: .maskControl
        case 63: .maskSecondaryFn
        default: nil
        }
    }
}

@MainActor
private final class CorrectionFieldsView: NSView {
    let aliasField = NSTextField()
    let canonicalField = NSTextField()

    init(alias: String, canonical: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
        aliasField.stringValue = alias
        canonicalField.stringValue = canonical
        aliasField.placeholderString = "What Parrot recognized"
        canonicalField.placeholderString = "Correct spelling"

        let aliasRow = Self.row(label: "Recognized", field: aliasField)
        let canonicalRow = Self.row(label: "Preferred", field: canonicalField)
        let stack = NSStackView(views: [aliasRow, canonicalRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            aliasRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            canonicalRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func row(label: String, field: NSTextField) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.textColor = .secondaryLabelColor
        labelView.font = .systemFont(ofSize: 11)
        labelView.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let row = NSStackView(views: [labelView, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }
}

@MainActor
private final class DictionaryWindowController:
    NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate
{
    private let store: CorrectionDictionaryStore
    private let tableView = NSTableView()
    private var rows: [CorrectionEntry] = []
    private var observer: NSObjectProtocol?

    init(store: CorrectionDictionaryStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Parrot Dictionary"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let title = NSTextField(labelWithString: "Learned vocabulary")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(
            wrappingLabelWithString:
                "Used by the speech decoder during recognition. Double-click a cell to edit."
        )
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)

        let aliasColumn = NSTableColumn(identifier: .init("alias"))
        aliasColumn.title = "Previously heard"
        aliasColumn.minWidth = 180
        let canonicalColumn = NSTableColumn(identifier: .init("canonical"))
        canonicalColumn.title = "Preferred spelling"
        canonicalColumn.minWidth = 180
        tableView.addTableColumn(aliasColumn)
        tableView.addTableColumn(canonicalColumn)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let addButton = NSButton(title: "Add…", target: self, action: #selector(addEntry))
        let removeButton = NSButton(
            title: "Remove",
            target: self,
            action: #selector(removeSelected)
        )
        let buttonRow = NSStackView(views: [addButton, removeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [title, detail, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
                scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            ])
        }

        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .parrotDictionaryDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let entry = rows[row]
        let field = NSTextField()
        field.isBordered = false
        field.backgroundColor = .clear
        field.isEditable = true
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(
            "\(tableColumn.identifier.rawValue)|\(entry.id.uuidString)"
        )
        field.stringValue = tableColumn.identifier.rawValue == "alias"
            ? entry.alias
            : entry.canonical
        return field
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let identifier = field.identifier?.rawValue.split(separator: "|"),
              identifier.count == 2,
              let id = UUID(uuidString: String(identifier[1])),
              let entry = rows.first(where: { $0.id == id })
        else { return }
        let alias = identifier[0] == "alias" ? field.stringValue : entry.alias
        let canonical = identifier[0] == "canonical" ? field.stringValue : entry.canonical
        if !store.update(id: id, alias: alias, canonical: canonical) {
            NSSound.beep()
            reload()
        }
    }

    @objc private func addEntry() {
        let fields = CorrectionFieldsView(alias: "", canonical: "")
        let alert = NSAlert()
        alert.messageText = "Add correction"
        alert.accessoryView = fields
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if store.upsert(
            alias: fields.aliasField.stringValue,
            canonical: fields.canonicalField.stringValue
        ) == nil {
            NSSound.beep()
        }
    }

    @objc private func removeSelected() {
        let ids = tableView.selectedRowIndexes.compactMap {
            rows.indices.contains($0) ? rows[$0].id : nil
        }
        for id in ids {
            store.remove(id: id)
        }
    }

    private func reload() {
        rows = store.entries
        tableView.reloadData()
    }
}
