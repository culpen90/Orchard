import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            globalHotKey = try GlobalHotKey {
                DispatchQueue.main.async {
                    HotKeyCenter.shared.didPress()
                }
            }
            HotKeyCenter.shared.didRegister()
        } catch {
            HotKeyCenter.shared.didFailRegistration(error.localizedDescription)
            NSLog("Orchard hotkey unavailable: %@", error.localizedDescription)
        }
    }
}
