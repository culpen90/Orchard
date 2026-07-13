@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

enum SpeechRecognitionState: Equatable, Sendable {
    case idle
    case authorizing
    case listening
}

@MainActor
@Observable
final class SpeechRecognizer {
    private(set) var state: SpeechRecognitionState = .idle
    private(set) var transcript = ""
    private(set) var errorMessage: String?
    private(set) var recoverySettingsURL: URL?

    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var autoSubmit = true
    @ObservationIgnored private var onUpdate: (@MainActor (String) -> Void)?
    @ObservationIgnored private var onFinal: (@MainActor (String) -> Void)?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start(
        onDeviceOnly: Bool,
        autoSubmit: Bool,
        onUpdate: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (String) -> Void
    ) async {
        guard state == .idle else {
            return
        }

        errorMessage = nil
        recoverySettingsURL = nil
        transcript = ""
        state = .authorizing

        do {
            try await requestPermissions()
            try startAudioRecognition(onDeviceOnly: onDeviceOnly)
            self.autoSubmit = autoSubmit
            self.onUpdate = onUpdate
            self.onFinal = onFinal
            state = .listening
        } catch {
            cleanUp()
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            recoverySettingsURL = (error as? SpeechRecognitionError)?.recoverySettingsURL
        }
    }

    func finish(submit: Bool) {
        guard state == .listening || state == .authorizing else {
            return
        }

        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let completion = onFinal
        cleanUp()

        if submit, !finalTranscript.isEmpty {
            completion?(finalTranscript)
        }
    }

    func cancel() {
        cleanUp()
    }

    func dismissError() {
        errorMessage = nil
        recoverySettingsURL = nil
    }

    private func startAudioRecognition(onDeviceOnly: Bool) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechRecognitionError.unavailable
        }
        if onDeviceOnly, !recognizer.supportsOnDeviceRecognition {
            throw SpeechRecognitionError.onDeviceUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = onDeviceOnly
        recognitionRequest = request

        let sink = AudioBufferSink(request: request)
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw SpeechRecognitionError.noAudioInput
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: recordingFormat,
            block: Self.makeAudioTap(sink: sink)
        )
        tapInstalled = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription

            Task { @MainActor [weak self, text, errorMessage] in
                self?.handleRecognition(
                    text: text,
                    isFinal: isFinal,
                    errorMessage: errorMessage
                )
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func handleRecognition(
        text: String?,
        isFinal: Bool,
        errorMessage: String?
    ) {
        guard state == .listening else {
            return
        }

        if let text {
            transcript = text
            onUpdate?(text)
            scheduleSilenceFinish()
        }

        if isFinal {
            finish(submit: autoSubmit)
        } else if let errorMessage {
            let hasTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasTranscript {
                finish(submit: autoSubmit)
            } else {
                cleanUp()
                self.errorMessage = errorMessage
            }
        }
    }

    private func scheduleSilenceFinish() {
        silenceTask?.cancel()
        guard autoSubmit else {
            return
        }

        silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.35))
                try Task.checkCancellation()
                self?.finish(submit: true)
            } catch {
                // A newer partial result or explicit stop cancelled this timer.
            }
        }
    }

    private func cleanUp() {
        silenceTask?.cancel()
        silenceTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        onUpdate = nil
        onFinal = nil
        state = .idle
    }

    private func requestPermissions() async throws {
        let speechStatus = await Self.speechAuthorizationStatus()
        guard speechStatus == .authorized else {
            throw SpeechRecognitionError.speechPermissionDenied
        }

        let microphoneGranted = await Self.microphoneAccessGranted()
        guard microphoneGranted else {
            throw SpeechRecognitionError.microphonePermissionDenied
        }
    }

    private nonisolated static func speechAuthorizationStatus() async
        -> SFSpeechRecognizerAuthorizationStatus
    {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else {
            return current
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private nonisolated static func makeAudioTap(
        sink: AudioBufferSink
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            sink.append(buffer)
        }
    }
}

private final class AudioBufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }
}

enum SpeechRecognitionError: LocalizedError, Sendable {
    case unavailable
    case onDeviceUnavailable
    case noAudioInput
    case speechPermissionDenied
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Speech recognition is not available right now."
        case .onDeviceUnavailable:
            "On-device recognition is not available for this language. Turn off On-device only in Settings."
        case .noAudioInput:
            "Orchard could not find a working microphone input."
        case .speechPermissionDenied:
            "Speech Recognition permission is off. Enable Orchard in System Settings > Privacy & Security > Speech Recognition."
        case .microphonePermissionDenied:
            "Microphone permission is off. Enable Orchard in System Settings > Privacy & Security > Microphone."
        }
    }

    var recoverySettingsURL: URL? {
        switch self {
        case .speechPermissionDenied:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            )
        case .microphonePermissionDenied:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        case .unavailable, .onDeviceUnavailable, .noAudioInput:
            nil
        }
    }
}
