import Carbon.HIToolbox
import AppKit

/// Registers a system-wide hotkey that fires even when another app (your
/// meeting window) is focused. Uses the Carbon Hot Key API, which is still
/// the most reliable way to get a true global shortcut on macOS.
///
/// Default in this app: ⌥⌘R  (option + command + R).
///
/// Carbon hotkeys work while the app is in the background, but on a
/// hardened/sandboxed build macOS may still require the app to appear under
/// System Settings › Privacy & Security › Accessibility for delivery from
/// some contexts. If the hotkey doesn't fire, check there first.
final class GlobalHotkey {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `UInt32(kVK_ANSI_R)`.
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | optionKey)`.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let unwrapped = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                unwrapped.handler()
                return noErr
            },
            1, &eventSpec, selfPtr, &eventHandler)

        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x48504B59), id: 1) // 'HPKY'
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)

        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
