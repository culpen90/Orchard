import SwiftUI

@main
struct OrchardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var assistant = AssistantStore()
    @State private var hotKeyCenter = HotKeyCenter.shared

    var body: some Scene {
        Window("Orchard", id: "assistant") {
            AssistantView(assistant: assistant)
                .frame(minWidth: 620, minHeight: 520)
        }
        .defaultSize(width: 760, height: 680)
        .commands {
            CommandMenu("Assistant") {
                Button("Start or Stop Listening") {
                    Task { await assistant.toggleListening() }
                }

                Button("New Conversation") {
                    assistant.newConversation()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView(assistant: assistant)
        } label: {
            MenuBarLabel(
                assistant: assistant,
                hotKeyCenter: hotKeyCenter
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                assistant: assistant,
                hotKeyCenter: hotKeyCenter
            )
        }
    }
}
