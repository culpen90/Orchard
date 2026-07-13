import Carbon
import Foundation
import Observation

@MainActor
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private(set) var pressCount: UInt = 0
    private(set) var registrationError: String?

    private init() {}

    func didPress() {
        pressCount &+= 1
    }

    func didRegister() {
        registrationError = nil
    }

    func didFailRegistration(_ message: String) {
        registrationError = message
    }
}

final class GlobalHotKey: @unchecked Sendable {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: @Sendable () -> Void

    init(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey),
        handler: @escaping @Sendable () -> Void
    ) throws {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotKey = Unmanaged<GlobalHotKey>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                hotKey.handler()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            throw GlobalHotKeyError.registrationFailed(installStatus)
        }

        let identifier = EventHotKeyID(signature: 0x4F_52_43_48, id: 1) // ORCH
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registerStatus == noErr else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
            self.eventHandler = nil
            throw GlobalHotKeyError.registrationFailed(registerStatus)
        }
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}

enum GlobalHotKeyError: LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            "Could not register Option-Space as Orchard's shortcut (\(status))."
        }
    }
}
