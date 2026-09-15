import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// What a global shortcut does.
enum ShortcutAction: UInt32, CaseIterable, Identifiable {
    case openLatest = 1
    case clearAll = 2

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .openLatest: "Son bildirimi aç"
        case .clearAll: "Tüm bildirimleri temizle"
        }
    }

    /// Where its key combination is saved.
    var prefKey: String {
        switch self {
        case .openLatest: "shortcutOpenLatest"
        case .clearAll: "shortcutClearAll"
        }
    }
}

/// A key with modifiers, saved as "keyCode|modifiers|key", where key is how it's shown (e.g. "N").
struct KeyCombo: Equatable {
    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Boşluk", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let key: String

    init?(storage: String) {
        let parts = storage.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = UInt16(parts[0]), let flags = UInt(parts[1]), !parts[2].isEmpty else { return nil }
        keyCode = code
        modifiers = NSEvent.ModifierFlags(rawValue: flags).intersection(Self.allowedModifiers)
        key = String(parts[2])
    }

    /// The combination pressed, or nil without ⌘, ⌥ or ⌃: a shortcut on a plain key would take that
    /// key away from every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.allowedModifiers)
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        keyCode = event.keyCode
        modifiers = flags
        key = Self.specialKeys[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !key.isEmpty else { return nil }
    }

    var storage: String {
        "\(keyCode)|\(modifiers.rawValue)|\(key)"
    }

    /// The way macOS menus show it: "⌃⌥⌘N".
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    func sameKeys(as other: KeyCombo) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// "Glnt": marks Glint's hot keys.
private let hotKeySignature: OSType = 0x476C_6E74

/// Shortcuts that work whichever app is in front, through Carbon's hot keys, which need no permission.
@MainActor
@Observable
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()

    /// Shortcuts whose combination another app (or macOS) already uses.
    private(set) var unavailable: Set<ShortcutAction> = []
    @ObservationIgnored var handler: ((ShortcutAction) -> Void)?
    @ObservationIgnored private var hotKeys: [ShortcutAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    private init() {}

    /// Registers the saved shortcuts in place of the ones registered before.
    func reload() {
        suspend()
        installEventHandler()
        var unavailable: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let combo = UserDefaults.standard.string(forKey: action.prefKey).flatMap(KeyCombo.init(storage:)) else { continue }
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(signature: hotKeySignature, id: action.rawValue)
            if RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr,
               let hotKey {
                hotKeys[action] = hotKey
            } else {
                unavailable.insert(action)
            }
        }
        if unavailable != self.unavailable {
            self.unavailable = unavailable
        }
    }

    /// Unregisters every shortcut, e.g. while a new combination is recorded.
    func suspend() {
        for hotKey in hotKeys.values {
            _ = UnregisterEventHotKey(hotKey)
        }
        hotKeys.removeAll()
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == hotKeySignature, let action = ShortcutAction(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { GlobalShortcuts.shared.handler?(action) }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }
}

/// A shortcut's row: its combination (click to record a new one; Esc cancels) and a button to remove it.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @AppStorage private var stored: String
    @State private var recording = false
    @State private var monitor: Any?

    init(action: ShortcutAction) {
        self.action = action
        _stored = AppStorage(wrappedValue: "", action.prefKey)
    }

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                if GlobalShortcuts.shared.unavailable.contains(action), !recording {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Bu kısayolu başka bir uygulama kullanıyor; başka bir tuş seç.")
                }
                Button(recording ? "Tuşlara bas…" : (KeyCombo(storage: stored)?.display ?? "Kısayol Ata")) {
                    if recording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                if !stored.isEmpty, !recording {
                    Button {
                        save("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Kısayolu kaldır")
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        // Otherwise pressing a registered combination runs it instead of reaching the monitor.
        GlobalShortcuts.shared.suspend()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let combo = KeyCombo(event: event) {
                save(combo.storage)
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
        GlobalShortcuts.shared.reload()
    }

    /// One combination does one thing: another shortcut with the same keys is cleared.
    private func save(_ value: String) {
        if let combo = KeyCombo(storage: value) {
            for other in ShortcutAction.allCases where other != action {
                if let existing = UserDefaults.standard.string(forKey: other.prefKey).flatMap(KeyCombo.init(storage:)),
                   existing.sameKeys(as: combo) {
                    UserDefaults.standard.removeObject(forKey: other.prefKey)
                }
            }
        }
        stored = value
        GlobalShortcuts.shared.reload()
    }
}
