import SwiftUI

struct SettingsView: View {
    @Bindable var assistant: AssistantStore
    @Bindable var hotKeyCenter: HotKeyCenter

    @AppStorage(PreferenceKeys.modelID)
    private var modelID = AssistantPreferences.defaultModelID
    @AppStorage(PreferenceKeys.systemPrompt)
    private var systemPrompt = AssistantPreferences.defaultSystemPrompt
    @AppStorage(PreferenceKeys.speakResponses)
    private var speakResponses = true
    @AppStorage(PreferenceKeys.autoSubmitVoice)
    private var autoSubmitVoice = true
    @AppStorage(PreferenceKeys.confirmActions)
    private var confirmActions = true
    @AppStorage(PreferenceKeys.enableActions)
    private var enableActions = true
    @AppStorage(PreferenceKeys.onDeviceRecognition)
    private var onDeviceRecognition = false

    @State private var apiKey = ""

    var body: some View {
        TabView {
            connectionSettings
                .tabItem { Label("OpenRouter", systemImage: "network") }

            assistantSettings
                .tabItem { Label("Assistant", systemImage: "sparkles") }

            voiceSettings
                .tabItem { Label("Voice", systemImage: "waveform") }

            actionSettings
                .tabItem { Label("Actions", systemImage: "checkmark.shield") }

            aboutView
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .scenePadding()
        .frame(width: 580, height: 430)
        .onAppear {
            assistant.refreshAPIKeyState()
        }
        .onChange(of: modelID) { _, _ in assistant.preferencesDidChange() }
        .onChange(of: systemPrompt) { _, _ in assistant.preferencesDidChange() }
        .onChange(of: speakResponses) { _, _ in assistant.preferencesDidChange() }
        .onChange(of: autoSubmitVoice) { _, _ in assistant.preferencesDidChange() }
        .onChange(of: confirmActions) { _, _ in assistant.preferencesDidChange() }
        .onChange(of: enableActions) { _, _ in assistant.preferencesDidChange() }
        .onChange(of: onDeviceRecognition) { _, _ in assistant.preferencesDidChange() }
    }

    private var connectionSettings: some View {
        Form {
            Section("API key") {
                HStack {
                    SecureField(
                        assistant.hasAPIKey ? "A key is already saved" : "sk-or-…",
                        text: $apiKey
                    )
                    Button("Save") {
                        assistant.saveAPIKey(apiKey)
                        if assistant.hasAPIKey {
                            apiKey = ""
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove") {
                        assistant.deleteAPIKey()
                    }
                    .disabled(!assistant.hasAPIKey || assistant.usesEnvironmentAPIKey)
                }

                HStack(spacing: 6) {
                    Image(systemName: assistant.hasAPIKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(assistant.hasAPIKey ? OrchardTheme.green : .secondary)
                    Text(keyStatusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link(
                        "Manage keys",
                        destination: URL(string: "https://openrouter.ai/settings/keys")!
                    )
                }
                .font(.caption)
            }

            Section("Model") {
                TextField("OpenRouter model ID", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                Text("Use an OpenRouter model slug such as `~openai/gpt-latest`. Leave it blank to use the account default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Your typed prompts and conversation context are sent to OpenRouter and the selected model provider. The API key stays in Keychain and is never stored in app preferences.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var assistantSettings: some View {
        Form {
            Section("Behavior") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System instructions")
                    TextEditor(text: $systemPrompt)
                        .font(.body)
                        .frame(minHeight: 135)
                        .padding(6)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(.quaternary, lineWidth: 1)
                        }
                }
            }

            Section {
                Button("Restore Default Instructions") {
                    systemPrompt = AssistantPreferences.defaultSystemPrompt
                }
            }
        }
        .formStyle(.grouped)
    }

    private var voiceSettings: some View {
        Form {
            Section("Responses") {
                Toggle("Read completed responses aloud", isOn: $speakResponses)
                Text("Speech is produced on your Mac using SpeakPad's AVSpeechSynthesizer engine and the system voice settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dictation") {
                Toggle("Send after a short pause", isOn: $autoSubmitVoice)
                Toggle("Require on-device recognition", isOn: $onDeviceRecognition)
                Text(onDeviceRecognition
                     ? "Audio stays on this Mac, but some languages may not support recognition."
                     : "macOS may send audio to Apple for speech recognition, depending on language and system support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                LabeledContent("Talk to Orchard") {
                    Text("⌥ Space")
                        .font(.system(.body, design: .monospaced).weight(.medium))
                }
                if let registrationError = hotKeyCenter.registrationError {
                    Label(registrationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Use the microphone button or Assistant menu while another app owns Option-Space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The global shortcut works without Accessibility or Input Monitoring permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var actionSettings: some View {
        Form {
            Section("Mac actions") {
                Toggle("Let the model propose Mac actions", isOn: $enableActions)
                Toggle("Ask before every action", isOn: $confirmActions)
                    .disabled(!enableActions)
                Text("Actions require a model that supports tool calling. Turn them off if your selected model does not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Allowed actions") {
                Label("Open an installed application", systemImage: "app.dashed")
                Label("Open an HTTPS website", systemImage: "safari")
                Label("Search the web", systemImage: "magnifyingglass")
                Label("Copy text to the clipboard", systemImage: "doc.on.doc")
            }

            Section("Safety") {
                Text("Orchard does not expose shell commands, AppleScript, arbitrary files, messages, purchases, deletion, or Accessibility automation to the model. Unknown actions and unexpected arguments are rejected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutView: some View {
        VStack(spacing: 18) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 46))
                .foregroundStyle(OrchardTheme.gradient)
            VStack(spacing: 5) {
                Text("Orchard")
                    .font(.title2.weight(.semibold))
                Text("Version 0.1.0")
                    .foregroundStyle(.secondary)
            }
            Text("A native, source-available macOS voice assistant powered by OpenRouter and SpeakPad.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 18) {
                Link(
                    "Orchard on GitHub",
                    destination: URL(string: "https://github.com/culpen90/Orchard")!
                )
                Link(
                    "SpeakPad",
                    destination: URL(string: "https://github.com/culpen90/SpeakPad")!
                )
                Link(
                    "OpenRouter",
                    destination: URL(string: "https://openrouter.ai")!
                )
                Link(
                    "License",
                    destination: URL(
                        string: "https://polyformproject.org/licenses/noncommercial/1.0.0"
                    )!
                )
            }
            .font(.callout)
            Text("SpeakPad speech components are used under the MIT License. Orchard is distributed under the PolyForm Noncommercial License 1.0.0. Both notices are included in the app bundle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            Spacer()
        }
        .padding(.top, 34)
        .padding(.horizontal, 34)
    }

    private var keyStatusText: String {
        if assistant.usesEnvironmentAPIKey {
            "Using OPENROUTER_API_KEY from the environment"
        } else if assistant.hasAPIKey {
            "Saved securely in macOS Keychain"
        } else {
            "No API key saved"
        }
    }
}
