import AppKit
import Carbon.HIToolbox

nonisolated enum HotKeyError: LocalizedError {
    case alreadyInUse(HotKey)
    case failed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyInUse(let k): "\(k.displayString) is already used by another app."
        case .failed(let status): "Could not register the shortcut (error \(status))."
        }
    }
}

/// Registers system-wide hotkeys with Carbon's `RegisterEventHotKey` — still the only public API that
/// fires while other apps are frontmost *and* consumes the chord, without Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x4D43_4244 // 'MCBD'

    private init() {}

    @discardableResult
    func register(_ hotKey: HotKey, handler: @escaping () -> Void) throws -> UInt32 {
        installEventHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(hotKey.keyCode), hotKey.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            if status == eventHotKeyExistsErr { throw HotKeyError.alreadyInUse(hotKey) }
            throw HotKeyError.failed(status)
        }
        refs[id] = ref
        handlers[id] = handler
        Log.input.info("registered hotkey \(hotKey.displayString) id=\(id)")
        return id
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, 1, &spec, nil, &eventHandler)
    }
}

/// Carbon delivers hot key events on the main thread.
private nonisolated func hotKeyEventCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: hotKeyID.id) }
    return noErr
}
