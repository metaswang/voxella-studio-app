import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

enum VoiceInputShortcutOption: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case controlOptionV
    case controlShiftSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlOptionSpace: "⌃⌥Space"
        case .controlOptionV: "⌃⌥V"
        case .controlShiftSpace: "⌃⇧Space"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .controlOptionSpace, .controlShiftSpace: UInt32(kVK_Space)
        case .controlOptionV: UInt32(kVK_ANSI_V)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlOptionSpace, .controlOptionV: UInt32(controlKey | optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        }
    }

    var menuModifiers: NSEvent.ModifierFlags {
        switch self {
        case .controlOptionSpace, .controlOptionV: [.control, .option]
        case .controlShiftSpace: [.control, .shift]
        }
    }
}

@Observable
@MainActor
final class VoiceInputShortcutPreferences {
    static let shared = VoiceInputShortcutPreferences()

    private static let optionKey = "voiceInputShortcutOption"
    var option: VoiceInputShortcutOption {
        didSet {
            UserDefaults.standard.set(option.rawValue, forKey: Self.optionKey)
            VoiceInputShortcutService.shared.register(option)
        }
    }
    private(set) var registrationError: String?

    private init() {
        option = VoiceInputShortcutOption(
            rawValue: UserDefaults.standard.string(forKey: Self.optionKey) ?? ""
        ) ?? .controlOptionSpace
    }

    func restoreDefault() {
        option = .controlOptionSpace
    }

    fileprivate func setRegistrationError(_ error: String?) {
        registrationError = error
    }
}

@MainActor
final class VoiceInputShortcutService {
    static let shared = VoiceInputShortcutService()

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    private init() {}

    func start() {
        installHandlerIfNeeded()
        register(VoiceInputShortcutPreferences.shared.option)
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    func register(_ option: VoiceInputShortcutOption) {
        installHandlerIfNeeded()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x5658494E), id: 1)
        let status = RegisterEventHotKey(
            option.keyCode,
            option.modifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        if status == noErr {
            hotKey = reference
            VoiceInputShortcutPreferences.shared.setRegistrationError(nil)
        } else {
            VoiceInputShortcutPreferences.shared.setRegistrationError("The shortcut is already in use. Choose another one.")
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ in
                Task { @MainActor in VoiceInputCoordinator.shared.present() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if status != noErr {
            VoiceInputShortcutPreferences.shared.setRegistrationError("Couldn’t register the voice input shortcut.")
        }
    }
}
