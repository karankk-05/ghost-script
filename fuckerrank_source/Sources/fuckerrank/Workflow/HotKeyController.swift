import AppKit
import Carbon

enum WorkflowAction: UInt32, CaseIterable {
    case screenshot = 1, solve, flash, notes, theme, prompt
    var keyCode: UInt32 {
        switch self {
        case .screenshot: return UInt32(kVK_ANSI_S)
        case .solve: return UInt32(kVK_ANSI_M)
        case .flash: return UInt32(kVK_ANSI_R)
        case .notes: return UInt32(kVK_ANSI_E)
        case .theme: return UInt32(kVK_ANSI_Q)
        case .prompt: return UInt32(kVK_ANSI_D)
        }
    }
}

@MainActor
final class HotKeyController {
    var onAction: ((WorkflowAction) -> Void)?
    private var keys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var localMonitor: Any?

    func start() throws {
        stop()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, let action = WorkflowAction(rawValue: identifier.id) else { return result }
            let controller = Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.onAction?(action) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw failure(status) }
        for action in WorkflowAction.allCases {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(action.keyCode, UInt32(controlKey | shiftKey),
                EventHotKeyID(signature: 0x47535056, id: action.rawValue), GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else { stop(); throw failure(status) }
            keys.append(reference)
        }
        // Some input sources route keyDown directly to a focused window rather
        // than through the Carbon dispatcher. Handle those while this app is active.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.control, .shift, .command, .option])
            guard modifiers == [.control, .shift],
                  let action = WorkflowAction.allCases.first(where: { $0.keyCode == event.keyCode }) else { return event }
            MainActor.assumeIsolated { self?.onAction?(action) }
            return nil
        }
    }
    func stop() {
        keys.forEach { UnregisterEventHotKey($0) }; keys.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }
    private func failure(_ code: OSStatus) -> Error {
        NSError(domain: "Keyboard Shortcuts", code: Int(code), userInfo: [NSLocalizedDescriptionKey:
            "Could not register keyboard shortcuts (\(code)). Disable any existing shortcuts that use Control–Shift–S/M/R/E/Q/D, then relaunch. The menu actions remain available."])
    }
}
