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
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var pressed: Set<UInt32> = []
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x4D43_4244 // 'MCBD'

    private init() {}

    @discardableResult
    func register(_ hotKey: HotKey, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) throws -> UInt32 {
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
        releaseHandlers[id] = onRelease
        Log.input.info("registered hotkey \(hotKey.displayString) id=\(id)")
        return id
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
        releaseHandlers.removeValue(forKey: id)
        pressed.remove(id)
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    func fire(id: UInt32, released: Bool = false) {
        if released {
            guard pressed.remove(id) != nil else { return }
            releaseHandlers[id]?()
        } else if pressed.insert(id).inserted {
            handlers[id]?()
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var specs = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, specs.count, &specs, nil, &eventHandler)
    }
}

/// Carbon delivers hot key events on the main thread.
private nonisolated func hotKeyEventCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: hotKeyID.id, released: released) }
    return noErr
}
