import Carbon
import Foundation
import PasteAgent

/// Holds the @MainActor actions keyed by Carbon's EventHotKeyID. A C callback
/// cannot capture Swift state, so the box travels through InstallEventHandler's
/// userData pointer and dispatches back onto the main queue.
private final class HotkeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [UInt32: @MainActor () -> Void] = [:]

    func set(_ id: UInt32, _ action: @escaping @MainActor () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        actions[id] = action
    }

    func dispatch(id: UInt32) {
        lock.lock()
        let action = actions[id]
        lock.unlock()
        guard let action else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { action() }
        }
    }
}

/// Carbon RegisterEventHotKey wrapper. Registration failures (a shortcut
/// already claimed by another app) are reported, never fatal.
@MainActor
final class GlobalHotkeys {
    private let box = HotkeyBox()
    // Carbon owns these handles. Marked nonisolated so deinit can release
    // them; every other use stays on the main actor.
    private nonisolated(unsafe) var eventHandler: OpaquePointer?
    private nonisolated(unsafe) var refs: [OpaquePointer] = []

    init() {
        installHandler()
    }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(box).toOpaque()
        let handler: @convention(c) (
            OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
        ) -> Int32 = { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            let box = Unmanaged<HotkeyBox>.fromOpaque(data).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            box.dispatch(id: hotKeyID.id)
            return noErr
        }
        let result = withUnsafePointer(to: &spec) { pointer in
            InstallEventHandler(
                GetApplicationEventTarget(), handler, 1, pointer, userData, &eventHandler
            )
        }
        if result != noErr {
            NSLog("[paste] InstallEventHandler failed: %d", result)
        }
    }

    @discardableResult
    func register(_ hotkey: Hotkey, id: UInt32, action: @escaping @MainActor () -> Void) -> Bool {
        box.set(id, action)
        var ref: OpaquePointer?
        let hotKeyID = EventHotKeyID(signature: OSType(0x50545354), id: id) // 'PTST'
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            Self.carbonModifiers(hotkey.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("[paste] RegisterEventHotKey failed: %d (keyCode=%d)", status, hotkey.keyCode)
            return false
        }
        refs.append(ref)
        return true
    }

    func unregisterAll() {
        // Keep the Carbon event handler installed. Settings changes
        // unregister and re-register hotkeys with the same IDs; removing the
        // handler here would leave every new registration with no callback.
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    deinit {
        // The object lives for the whole process today, but if it is ever
        // torn down the Carbon handler must go too — its userData is an
        // unretained pointer back to `box`.
        for ref in refs { UnregisterEventHotKey(ref) }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private static func carbonModifiers(_ modifiers: Hotkey.Modifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}
