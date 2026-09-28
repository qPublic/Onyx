import AppKit
import SwiftUI
import AVFoundation
import Speech
import Combine

// MARK: - Voice for Onyx AI: speak your question (on-device speech recognition), hear the answer

/// Listens to the microphone and turns speech into text on this Mac (Apple's SpeechAnalyzer). It stops by itself
/// after a short pause, then hands the text over.
@MainActor final class VoiceInput: ObservableObject {
    static let shared = VoiceInput()
    enum State: Equatable { case idle, preparing, listening, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var silence: Timer?
    private var finished = "", volatile = ""
    private var lastChange = Date(), began = Date()
    private var onDone: ((String) -> Void)?

    var active: Bool { state == .listening || state == .preparing }
    func dismissError() { if case .failed = state { state = .idle } }

    func toggle(_ done: @escaping (String) -> Void) {
        if active { stop() } else { Task { await start(done) } }
    }

    func start(_ done: @escaping (String) -> Void) async {
        onDone = done; transcript = ""; finished = ""; volatile = ""
        state = .preparing
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .failed("Allow Onyx to use the microphone in System Settings › Privacy & Security › Microphone.")
            return
        }
        do {
            let transcriber = try await Self.transcriber()
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw VoiceError("Speech recognition isn't available for your language.")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            self.analyzer = analyzer; self.feed = feed
            results = Task { [weak self] in
                do {
                    for try await r in transcriber.results { self?.heard(String(r.text.characters), final: r.isFinal) }
                } catch {}
            }
            try await analyzer.start(inputSequence: stream)
            try startMic(format: format, into: feed)
            state = .listening
            began = Date(); lastChange = Date()
            silence = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkSilence() }
            }
        } catch {
            teardown()
            state = .failed((error as? VoiceError)?.message ?? "Voice input didn't start: \(error.localizedDescription)")
        }
    }

    /// Stops listening; the text so far is sent unless `send` is false.
    func stop(send: Bool = true) {
        guard active else { return }
        silence?.invalidate(); silence = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        feed?.finish()
        let analyzer = self.analyzer, results = self.results, done = onDone
        state = .idle
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await Self.wait(for: results, seconds: 2)   // the last words arrive as the analyzer finishes
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            teardown()
            if send, !text.isEmpty { done?(text) }
        }
    }

    private func heard(_ text: String, final: Bool) {
        if final { finished += text; volatile = "" } else { volatile = text }
        transcript = (finished + volatile).trimmingCharacters(in: .whitespaces)
        lastChange = Date()
    }

    /// A pause after you've said something sends it; nothing said for 8 seconds just stops.
    private func checkSilence() {
        guard state == .listening else { return }
        let quiet = Date().timeIntervalSince(lastChange)
        if !transcript.isEmpty && quiet > 1.6 { stop() }
        else if transcript.isEmpty && quiet > 8 { stop(send: false) }
        else if Date().timeIntervalSince(began) > 60 { stop() }
    }

    private func teardown() {
        results?.cancel(); results = nil; analyzer = nil; feed = nil; engine = nil
    }

    private func startMic(format: AVAudioFormat, into feed: AsyncStream<AnalyzerInput>.Continuation) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode, inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let tap = Self.converterTap(from: inFormat, to: format, into: feed) else {
            throw VoiceError("No microphone found.")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat, block: tap)
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Converts microphone buffers to the analyzer's format. Built outside the main actor: it runs on the audio thread.
    nonisolated static func converterTap(from inFormat: AVAudioFormat, to format: AVAudioFormat,
                                         into feed: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock? {
        guard let converter = AVAudioConverter(from: inFormat, to: format) else { return nil }
        return { buffer, _ in
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / inFormat.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            if error == nil, out.frameLength > 0 { feed.yield(AnalyzerInput(buffer: out)) }
        }
    }

    /// The on-device transcriber for your language, downloading Apple's speech model the first time if needed.
    nonisolated static func transcriber() async throws -> SpeechTranscriber {
        var found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if found == nil { found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) }
        guard let locale = found else { throw VoiceError("Speech recognition isn't available for your language.") }
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
        return t
    }

    nonisolated static func wait(for task: Task<Void, Never>?, seconds: Double) async {
        guard let task else { return }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await task.value }
            g.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await g.next(); g.cancelAll()
        }
    }
}

struct VoiceError: Error { let message: String; init(_ m: String) { message = m } }

// MARK: - Spoken answers

@MainActor final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    static let key = "ai.speak"            // "off", "voice" (only answers to spoken questions), "always"
    static var askedByVoice = false
    @Published private(set) var speakingID: UUID?
    private let synth = AVSpeechSynthesizer()
    private var bag = Set<AnyCancellable>()

    override init() { super.init(); synth.delegate = self }

    /// Speaks each finished answer when the "Speak answers" setting says so.
    func start() {
        Assistant.shared.$busy.removeDuplicates().dropFirst().filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let mode = Prefs.string(Self.key), voice = Self.askedByVoice
                Self.askedByVoice = false
                guard mode == "always" || (mode == "voice" && voice),
                      let last = Assistant.shared.messages.last, last.role == .assistant, !last.text.isEmpty else { return }
                self?.speak(last.text, id: last.id)
            }
            .store(in: &bag)
    }

    func speak(_ text: String, id: UUID? = nil) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: Self.speakable(text))
        u.voice = Self.bestVoice()
        speakingID = id
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate); speakingID = nil }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in self.speakingID = nil } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Task { @MainActor in self.speakingID = nil } }

    /// The best-sounding installed voice for your language (Premium or Enhanced if you've downloaded one).
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == lang && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// Answers written for reading → for listening: no markdown symbols, math symbols said as words.
    static func speakable(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        for (a, b) in [("m∠", "the measure of angle "), ("∠", "angle "), ("≅", " is congruent to "), ("≤", " is at most "), ("≥", " is at least "),
                       ("√", "square root of "), ("×", " times "), ("÷", " divided by "), ("≠", " is not equal to ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}

// MARK: - The mic button in the AI tab

struct MicButton: View {
    @ObservedObject var voice = VoiceInput.shared
    let send: (String) -> Void

    var body: some View {
        Button { voice.toggle(send) } label: {
            switch voice.state {
            case .preparing: ProgressView().controlSize(.small)
            case .listening: Image(systemName: "mic.fill").foregroundStyle(.red).symbolEffect(.pulse, options: .repeating)
            default: Image(systemName: "mic")
            }
        }
        .buttonStyle(.plain)
        .help(voice.state == .listening ? "Listening. Stop talking to send, or click to stop" : "Ask by voice (recognized on this Mac)")
    }
}
