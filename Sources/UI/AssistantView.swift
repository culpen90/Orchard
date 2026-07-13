import SwiftUI

struct AssistantView: View {
    @Bindable var assistant: AssistantStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    OrchardTheme.green.opacity(0.10),
                    Color(nsColor: .windowBackgroundColor),
                    OrchardTheme.gold.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                AssistantHeader(assistant: assistant, openSettings: openSettings.callAsFunction)
                Divider().opacity(0.55)
                conversation
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AssistantInputBar(assistant: assistant)
        }
        .alert(
            "Orchard needs attention",
            isPresented: Binding(
                get: { visibleError != nil },
                set: { isPresented in
                    if !isPresented {
                        assistant.dismissError()
                    }
                }
            )
        ) {
            Button("OK") {
                assistant.dismissError()
            }
            if let recoveryURL = assistant.speechRecognizer.recoverySettingsURL {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(recoveryURL)
                }
            }
        } message: {
            Text(visibleError ?? "Unknown error")
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if !assistant.hasAPIKey {
                        APIKeySetupCard(assistant: assistant)
                            .padding(.bottom, 4)
                    }

                    if assistant.messages.isEmpty {
                        WelcomeView(assistant: assistant)
                    } else {
                        ForEach(assistant.messages) { message in
                            MessageBubble(message: message, assistant: assistant)
                                .id(message.id)
                        }
                    }

                    if let proposal = assistant.pendingAction {
                        ActionConfirmationCard(
                            proposal: proposal,
                            approve: { assistant.resolvePendingAction(approved: true) },
                            decline: { assistant.resolvePendingAction(approved: false) }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: assistant.messages.last?.content) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: assistant.messages.last?.activities.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: assistant.pendingAction) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var visibleError: String? {
        assistant.lastError
            ?? assistant.speechRecognizer.errorMessage
            ?? assistant.speechController.errorMessage
    }
}

private struct AssistantHeader: View {
    @Bindable var assistant: AssistantStore
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(OrchardTheme.gradient)
                Image(systemName: "leaf.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            .shadow(color: OrchardTheme.green.opacity(0.22), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Orchard")
                    .font(.title3.weight(.semibold))
                Text(assistant.modelDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            StatusPill(status: assistant.status)

            Button {
                assistant.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New conversation")
            .buttonStyle(.borderless)

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }
}

private struct StatusPill: View {
    let status: AssistantStatus

    var body: some View {
        HStack(spacing: 6) {
            if case .thinking = status {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: status.symbolName)
                    .symbolEffect(.pulse, isActive: status == .listening)
            }
            Text(status.title)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(statusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.11), in: Capsule())
    }

    private var statusColor: Color {
        switch status {
        case .ready:
            OrchardTheme.green
        case .listening:
            .red
        case .thinking:
            .blue
        case .awaitingConfirmation:
            OrchardTheme.gold
        case .speaking, .paused:
            .purple
        }
    }
}

private struct WelcomeView: View {
    @Bindable var assistant: AssistantStore

    private let suggestions = [
        "Give me a quick plan for today",
        "Open Safari",
        "Search the web for local weather"
    ]

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(OrchardTheme.gradient)
            VStack(spacing: 6) {
                Text("What can I help with?")
                    .font(.title2.weight(.semibold))
                Text("Type a request or press Option-Space and speak.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 9) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        assistant.submit(suggestion)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!assistant.hasAPIKey)
                }
            }
            .controlSize(.small)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @Bindable var assistant: AssistantStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 90)
            } else {
                Image(systemName: "leaf.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(OrchardTheme.gradient, in: Circle())
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                VStack(
                    alignment: message.role == .user ? .trailing : .leading,
                    spacing: 8
                ) {
                    if message.content.isEmpty {
                        if message.deliveryState == .streaming {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(assistant.activityText ?? "Thinking")
                                    .foregroundStyle(.secondary)
                            }
                        } else if message.deliveryState == .interrupted {
                            Label("Response interrupted", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(message.content)
                            .textSelection(.enabled)
                    }

                    ForEach(Array(message.activities.enumerated()), id: \.offset) { _, activity in
                        Label(activity, systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(OrchardTheme.green)
                    }

                    if message.deliveryState == .interrupted, !message.content.isEmpty {
                        Label("Response interrupted", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background {
                    bubbleBackground
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                if message.role == .assistant, !message.content.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            assistant.copy(message)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button {
                            assistant.replay(message)
                        } label: {
                            Label("Read", systemImage: "speaker.wave.2")
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                }
            }
            .frame(maxWidth: 590, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.role == .user {
            OrchardTheme.green.opacity(0.17)
        } else {
            Color(nsColor: .controlBackgroundColor).opacity(0.92)
        }
    }
}

private struct ActionConfirmationCard: View {
    let proposal: ActionProposal
    let approve: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: proposal.symbolName)
                .font(.title3)
                .foregroundStyle(OrchardTheme.gold)
                .frame(width: 34, height: 34)
                .background(OrchardTheme.gold.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(proposal.title)
                    .font(.headline)
                Text(proposal.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .help(proposal.detail)

                HStack {
                    Button("Not Now", action: decline)
                    Button(proposal.confirmationTitle, action: approve)
                        .buttonStyle(.borderedProminent)
                        .tint(OrchardTheme.green)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(OrchardTheme.gold.opacity(0.30), lineWidth: 1)
        }
    }
}

private struct APIKeySetupCard: View {
    @Bindable var assistant: AssistantStore
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect OpenRouter", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(OrchardTheme.green)
            Text("Your key is saved in the macOS Keychain and is only sent to OpenRouter as a Bearer credential.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                SecureField("OpenRouter API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(OrchardTheme.green)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Link(
                "Create or manage a key on OpenRouter",
                destination: URL(string: "https://openrouter.ai/settings/keys")!
            )
            .font(.caption)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(OrchardTheme.green.opacity(0.28), lineWidth: 1)
        }
    }

    private func save() {
        assistant.saveAPIKey(apiKey)
        if assistant.hasAPIKey {
            apiKey = ""
        }
    }
}

private struct AssistantInputBar: View {
    @Bindable var assistant: AssistantStore
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    Task { await assistant.toggleListening() }
                } label: {
                    Image(
                        systemName: assistant.speechRecognizer.state == .idle
                            ? "mic.fill"
                            : "stop.fill"
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(assistant.speechRecognizer.state == .idle ? OrchardTheme.green : .red)
                .help(assistant.speechRecognizer.state == .idle ? "Start listening" : "Finish request")

                TextField("Ask Orchard anything…", text: $assistant.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.body)
                    .focused($inputFocused)
                    .onSubmit {
                        if assistant.canSend {
                            assistant.submit()
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(0.90),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.quaternary, lineWidth: 1)
                    }

                if assistant.isResponding {
                    Button {
                        assistant.cancelResponse()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop response")
                } else {
                    Button {
                        assistant.submit()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OrchardTheme.green)
                    .disabled(!assistant.canSend || !assistant.hasAPIKey)
                    .help("Send")
                }
            }

            HStack {
                Text("Option-Space to talk")
                Spacer()
                Text("Return to send")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 44)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
        .onAppear {
            inputFocused = true
        }
    }
}
