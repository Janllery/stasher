import Carbon

@MainActor
final class HotKey {
    struct Shortcut {
        let code: Int
        let letter: String

        var label: String { "Control + Shift + \(letter)" }

        static let preferred = Shortcut(code: kVK_ANSI_P, letter: "P")
        static let alternate = Shortcut(code: kVK_ANSI_L, letter: "L")
    }

    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func start() -> Shortcut? {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x5057524d, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let hotKey = Unmanaged<HotKey>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in hotKey.action() }
            return noErr
        }, 1, &specification, pointer, &handler)
        guard result == noErr else { return nil }

        let identifier = EventHotKeyID(signature: 0x5057524d, id: 1)
        for shortcut in [Shortcut.preferred, .alternate] {
            let registered = RegisterEventHotKey(UInt32(shortcut.code), UInt32(controlKey | shiftKey),
                                                 identifier, GetApplicationEventTarget(),
                                                 OptionBits(kEventHotKeyExclusive), &registration)
            if registered == noErr { return shortcut }
        }
        stop()
        return nil
    }

    func stop() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
    }
}
