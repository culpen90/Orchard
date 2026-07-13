import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Bindable var assistant: AssistantStore
    @Bindable var hotKeyCenter: HotKeyCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("Orchard", systemImage: assistant.status.symbolName)
            .onChange(of: hotKeyCenter.pressCount) { oldValue, newValue in
                guard oldValue != newValue else {
                    return
                }
                openAssistantWindow()
                Task { await assistant.toggleListening() }
            }
    }

    private func openAssistantWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Orchard" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "assistant")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct MenuBarView: View {
    @Bindable var assistant: AssistantStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "leaf.fill")
                    .font(.title2)
                    .foregroundStyle(OrchardTheme.gradient)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Orchard")
                        .font(.headline)
                    Label(assistant.status.title, systemImage: assistant.status.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                openAssistantWindow()
                Task { await assistant.toggleListening() }
            } label: {
                Label(
                    assistant.speechRecognizer.state == .idle ? "Talk to Orchard" : "Finish Request",
                    systemImage: assistant.speechRecognizer.state == .idle ? "mic.fill" : "stop.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(OrchardTheme.green)
            .controlSize(.large)

            Divider()

            VStack(spacing: 4) {
                menuButton("Open Conversation", systemImage: "bubble.left.and.bubble.right") {
                    openAssistantWindow()
                }

                menuButton("New Conversation", systemImage: "square.and.pencil") {
                    assistant.newConversation()
                    openAssistantWindow()
                }

                if assistant.speechController.playbackState == .speaking {
                    menuButton("Pause Speech", systemImage: "pause.fill") {
                        assistant.speechController.pause()
                    }
                } else if assistant.speechController.playbackState == .paused {
                    menuButton("Resume Speech", systemImage: "play.fill") {
                        assistant.speechController.resume()
                    }
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)

                menuButton("Quit Orchard", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func menuButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }

    private func openAssistantWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Orchard" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "assistant")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.title == "Orchard" })?
                .makeKeyAndOrderFront(nil)
        }
    }
}

enum OrchardTheme {
    static let green = Color(red: 0.19, green: 0.55, blue: 0.33)
    static let gold = Color(red: 0.95, green: 0.58, blue: 0.20)
    static let gradient = LinearGradient(
        colors: [green, gold],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
