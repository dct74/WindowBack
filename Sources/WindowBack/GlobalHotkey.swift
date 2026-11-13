import Carbon.HIToolbox
import Foundation

/// 全局快捷键（Carbon RegisterEventHotKey）。
/// 不用 CGEventTap / NSEvent 全局监听：那两个要辅助功能权限，而且我们只想要一个组合键。
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?

    /// 默认组合：⌃⌥⌘W。字母区里 Control+Option+Command 这一档基本没人占用。
    static let defaultKeyCode = UInt32(kVK_ANSI_W)
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    static var displayName: String { "⌃⌥⌘W" }

    @discardableResult
    func register(keyCode: UInt32 = defaultKeyCode,
                  modifiers: UInt32 = defaultModifiers,
                  onFire: @escaping () -> Void) -> Bool {
        unregister()
        self.onFire = onFire

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                hotkey.onFire?()
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5742_4B42), id: 1) // 'WBKB'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr && hotKeyRef != nil
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit { unregister() }
}
