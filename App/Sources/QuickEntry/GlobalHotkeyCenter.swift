import AppKit
import Carbon.HIToolbox
import Foundation

/// One global-hotkey registration: a virtual key code plus Carbon
/// modifier bits. A value type with the Carbon constants in one place,
/// because nothing else in the app may touch HIToolbox.
///
/// The string form (`"49:6144"`) is what persists in UserDefaults;
/// `symbolRepresentation` is what the user sees ("⌃⌥Space").
public struct HotkeySpec: Equatable, Sendable {
    public let keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`,
    /// `shiftKey`) — NOT `NSEvent.ModifierFlags` bits.
    public let carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(keyCode: UInt32, eventModifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, carbonModifiers: Self.carbonBits(eventModifiers))
    }

    /// The SPEC §5.11 default: ⌃⌥Space.
    public static let quickEntryDefault = HotkeySpec(
        keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey))

    /// The UserDefaults key the spec persists under (F-SET Shortcuts).
    public static let defaultsKey = "QuickEntryHotkey"

    /// `NSEvent.ModifierFlags` → Carbon modifier bits.
    static func carbonBits(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        return bits
    }

    /// Carbon modifier bits → `NSEvent.ModifierFlags` (the inverse of
    /// `carbonBits`), for a menu item's `keyEquivalentModifierMask`.
    public var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// The menu-item key equivalent for this spec ("" for keys a menu
    /// can't represent — those stay Carbon-only).
    public var keyEquivalentString: String {
        switch keyCode {
        case UInt32(kVK_Space): " "
        case UInt32(kVK_Return): "\r"
        case UInt32(kVK_Tab): "\t"
        case UInt32(kVK_Delete): "\u{7f}"
        case UInt32(kVK_Escape): "\u{1b}"
        case UInt32(kVK_LeftArrow): "\u{f702}"
        case UInt32(kVK_RightArrow): "\u{f703}"
        case UInt32(kVK_UpArrow): "\u{f700}"
        case UInt32(kVK_DownArrow): "\u{f701}"
        default:
            if keyCode >= UInt32(kVK_F1), keyCode <= UInt32(kVK_F12) {
                UnicodeScalar(0xF704 + Int(keyCode) - kVK_F1).map(String.init) ?? ""
            } else if let letter = Self.lowercaseLetter(keyCode) {
                letter
            } else {
                ""
            }
        }
    }

    /// The unshifted ANSI character for letter/digit key codes, so a
    /// recorded ⌃⌥J shows in the menu as a real equivalent.
    static func lowercaseLetter(_ keyCode: UInt32) -> String? {
        let letters: [(code: UInt32, character: String)] = [
            (UInt32(kVK_ANSI_A), "a"), (UInt32(kVK_ANSI_B), "b"), (UInt32(kVK_ANSI_C), "c"),
            (UInt32(kVK_ANSI_D), "d"), (UInt32(kVK_ANSI_E), "e"), (UInt32(kVK_ANSI_F), "f"),
            (UInt32(kVK_ANSI_G), "g"), (UInt32(kVK_ANSI_H), "h"), (UInt32(kVK_ANSI_I), "i"),
            (UInt32(kVK_ANSI_J), "j"), (UInt32(kVK_ANSI_K), "k"), (UInt32(kVK_ANSI_L), "l"),
            (UInt32(kVK_ANSI_M), "m"), (UInt32(kVK_ANSI_N), "n"), (UInt32(kVK_ANSI_O), "o"),
            (UInt32(kVK_ANSI_P), "p"), (UInt32(kVK_ANSI_Q), "q"), (UInt32(kVK_ANSI_R), "r"),
            (UInt32(kVK_ANSI_S), "s"), (UInt32(kVK_ANSI_T), "t"), (UInt32(kVK_ANSI_U), "u"),
            (UInt32(kVK_ANSI_V), "v"), (UInt32(kVK_ANSI_W), "w"), (UInt32(kVK_ANSI_X), "x"),
            (UInt32(kVK_ANSI_Y), "y"), (UInt32(kVK_ANSI_Z), "z"),
            (UInt32(kVK_ANSI_0), "0"), (UInt32(kVK_ANSI_1), "1"), (UInt32(kVK_ANSI_2), "2"),
            (UInt32(kVK_ANSI_3), "3"), (UInt32(kVK_ANSI_4), "4"), (UInt32(kVK_ANSI_5), "5"),
            (UInt32(kVK_ANSI_6), "6"), (UInt32(kVK_ANSI_7), "7"), (UInt32(kVK_ANSI_8), "8"),
            (UInt32(kVK_ANSI_9), "9"),
        ]
        return letters.first { $0.code == keyCode }?.character
    }

    /// True when at least one modifier is down — a global hotkey that is
    /// a bare printable key would swallow ordinary typing in every app.
    public var hasModifier: Bool { carbonModifiers != 0 }

    /// The plain-UserDefaults encoding (`"keyCode:carbonModifiers"`).
    public var defaultsString: String { "\(keyCode):\(carbonModifiers)" }

    /// Inverse of `defaultsString`; nil for malformed input.
    public init?(defaultsString: String) {
        let parts = defaultsString.split(separator: ":")
        guard parts.count == 2,
            let code = UInt32(parts[0]),
            let modifiers = UInt32(parts[1])
        else { return nil }
        self.init(keyCode: code, carbonModifiers: modifiers)
    }

    /// The menu-style rendering, e.g. "⌃⌥Space".
    public var symbolRepresentation: String {
        var symbols = ""
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + Self.keyName(keyCode)
    }

    /// Human name for a virtual key code (the common ANSI pad, space,
    /// return, arrows and function keys); "#<code>" for anything else.
    public static func keyName(_ keyCode: UInt32) -> String {
        let known: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "Return",
            UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Escape): "Esc",
            UInt32(kVK_Delete): "Delete",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
        ]
        if let name = known[keyCode] { return name }
        if keyCode >= UInt32(kVK_F1), keyCode <= UInt32(kVK_F12) {
            return "F\(keyCode - UInt32(kVK_F1) + 1)"
        }
        return "#\(keyCode)"
    }
}

/// The Carbon event-handler trampoline. A plain C function pointer (no
/// captures); the center arrives through the handler's user data.
private let hotkeyEventCallback:
    @convention(c) (
        EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?
    ) -> OSStatus = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let size = MemoryLayout<EventHotKeyID>.size
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamUserData),
            EventParamType(typeEventHotKeyID),
            nil,
            size,
            nil,
            &hotKeyID)
        guard status == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
        // The reference itself is usable anywhere; only the hop onto the
        // main actor is needed to touch the center. Carbon delivers
        // application-target events on the main thread, so the assumption
        // below is safe, not a dispatch.
        let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated {
            center.hotkeyPressed()
        }
        return noErr
    }

/// A ~40-line in-app wrapper around Carbon's `RegisterEventHotKey`
/// (F-QEN-1, ADR-0020): no `KeyboardShortcuts`-style dependency, no
/// extra package. One hotkey at a time; re-registering swaps it
/// atomically. The singleton lives for the whole process, so the
/// trampoline's unretained back-reference is safe.
@MainActor
final class GlobalHotkeyCenter {
    static let shared = GlobalHotkeyCenter()

    /// Called on the main actor whenever the registered hotkey fires —
    /// in ANY application (that is what makes Quick Entry global).
    var onTrigger: (() -> Void)?

    /// The spec currently registered with the system, nil when none.
    private(set) var activeSpec: HotkeySpec?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    private init() {}

    /// Registers `spec` as the global hotkey, replacing any earlier one.
    /// Returns false when Carbon refuses (a conflict with another app's
    /// identical hotkey, typically); the previous registration, if any,
    /// stays live.
    @discardableResult
    func register(_ spec: HotkeySpec) -> Bool {
        unregister()
        installEventHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &reference)
        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        activeSpec = spec
        return true
    }

    /// Unregisters the current hotkey (called before a swap and on
    /// hotkey disabling).
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        activeSpec = nil
    }

    /// Carbon's four-char code identifying this app's hotkey event.
    private static let signature: OSType = {
        let raw: [UInt8] = [0x41, 0x72, 0x62, 0x51]  // "ArbQ"
        return OSType(raw[0]) << 24 | OSType(raw[1]) << 16 | OSType(raw[2]) << 8 | OSType(raw[3])
    }()

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventCallback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler)
        if status != noErr {
            eventHandler = nil
        }
    }

    /// The Carbon trampoline lands here.
    func hotkeyPressed() {
        guard activeSpec != nil else { return }
        onTrigger?()
    }
}
