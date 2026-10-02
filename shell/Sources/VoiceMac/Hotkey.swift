import Carbon.HIToolbox

/// Hold-to-talk on Option-Space via a Carbon hotkey: press and release events, no Accessibility permission.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return noErr }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(user).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { hotkey.onPress() } else { hotkey.onRelease() }
            return noErr
        }, types.count, &types, me, &handler)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x564D4143), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}
