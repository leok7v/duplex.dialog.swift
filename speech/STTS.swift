import Speech
import Combine
import NaturalLanguage
import os

class STTS: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    @Published var transcript_log: [String] = []
    @Published var is_active: Bool = false
    @Published var is_running: Bool = false
    @Published var is_speech_detected: Bool = false
    @Published var selected_gender: Int = 0
    @Published var speech_rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @Published var speech_pitch: Double = 1.0

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    private var pendingSentences: [String] = []
    private var isSpeaking = false

    override init() {
        super.init()
        self.synthesizer.delegate = self
        self.configureLoudSpeaker()
    }

    private func configureLoudSpeaker() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            print("Audio session config failed: \(error)")
        }
        #endif
    }

    func start_dialog_session() {
        AVAudioApplication.requestRecordPermission { micGranted in
            guard micGranted else { return }
            SFSpeechRecognizer.requestAuthorization { status in
                guard status == .authorized else { return }
                DispatchQueue.main.async {
                    self.configureLoudSpeaker()
                    self.is_running = true
                    Task {
                        do {
                            try await self.startAudio()
                        } catch {
                            print("[STTS] start failed: \(error)")
                        }
                    }
                }
            }
        }
    }

    func stop_dialog_session() {
        self.is_running = false
        self.is_active = false
        self.is_speech_detected = false
        self.isSpeaking = false
        self.pendingSentences.removeAll()
        self.synthesizer.stopSpeaking(at: .immediate)
        self.continuation?.finish()
        self.continuation = nil
        if let a = self.analyzer {
            Task { await a.cancelAndFinishNow() }
            self.analyzer = nil
        }
        self.audioEngine.stop()
        self.audioEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Audio pipeline (VP + transcriber)

    private func startAudio() async throws {
        let transcriber = DictationTranscriber(
            locale: Locale(identifier: "en-US"),
            preset: .progressiveShortDictation
        )

        let modules: [any SpeechModule] = [transcriber]
        let install = try await AssetInventory
            .assetInstallationRequest(supporting: modules)
        try await install?.downloadAndInstall()

        guard let targetFormat = await SpeechAnalyzer
            .bestAvailableAudioFormat(
                compatibleWith: modules
            ),
            targetFormat.channelCount > 0,
            targetFormat.sampleRate > 0
        else {
            print("[STTS] no usable audio format")
            return
        }
        print("[STTS] target: \(targetFormat)")

        let input = self.audioEngine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            print("[STTS] VP enabled")
        } catch {
            print("[STTS] VP failed: \(error)")
        }

        let sourceFormat = input.outputFormat(forBus: 0)
        print("[STTS] source: \(sourceFormat)")

        let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceFormat.sampleRate,
            channels: 1
        )!
        let converter = AVAudioConverter(
            from: monoFormat, to: targetFormat
        )

        let (stream, cont) = AsyncStream
            .makeStream(of: AnalyzerInput.self)
        self.continuation = cont

        input.installTap(
            onBus: 0, bufferSize: 1024, format: sourceFormat
        ) { [weak self] buffer, _ in
            guard let self,
                  buffer.frameLength > 0,
                  let converter
            else { return }
            guard let mono = Self.extractMono(from: buffer),
                  let converted = Self.convert(
                      mono, with: converter, to: targetFormat
                  )
            else { return }
            self.continuation?.yield(
                AnalyzerInput(buffer: converted)
            )
        }

        self.audioEngine.prepare()
        try self.audioEngine.start()
        print("[STTS] engine started")

        let a = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = a
        Task {
            do { _ = try await a.analyzeSequence(stream) }
            catch { print("[STTS] analyzer failed: \(error)") }
        }

        Task { await self.handleTranscriber(transcriber) }

        await MainActor.run { self.is_active = true }
    }

    private static func extractMono(
        from buffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData?[0] else {
            return nil
        }
        let fmt = AVAudioFormat(
            standardFormatWithSampleRate:
                buffer.format.sampleRate,
            channels: 1
        )!
        guard let mono = AVAudioPCMBuffer(
            pcmFormat: fmt, frameCapacity: buffer.frameLength
        ) else { return nil }
        mono.frameLength = buffer.frameLength
        mono.floatChannelData![0].update(
            from: src, count: Int(buffer.frameLength)
        )
        return mono
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio
        ) + 1024
        guard let out = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: cap
        ) else { return nil }

        let consumed = OSAllocatedUnfairLock(initialState: false)
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            let give = consumed.withLock { flag -> Bool in
                guard !flag else { return false }
                flag = true
                return true
            }
            status.pointee = give ? .haveData : .noDataNow
            return give ? buffer : nil
        }
        return out.frameLength > 0 ? out : nil
    }

    // MARK: - Transcriber (continuous, also used for interruption)

    private func handleTranscriber(
        _ transcriber: DictationTranscriber
    ) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.isEmpty else { continue }

                if self.isSpeaking {
                    print("[STTS] interrupting (heard: '\(text)')")
                    await MainActor.run {
                        self.is_speech_detected = true
                        self.synthesizer
                            .stopSpeaking(at: .immediate)
                        self.pendingSentences.removeAll()
                        self.isSpeaking = false
                    }
                    continue
                }

                guard result.isFinal else { continue }
                print("[STTS] transcript: '\(text)'")
                await MainActor.run {
                    self.is_speech_detected = false
                    self.transcript_log.append("User: \(text)")
                    self.respond(to: text)
                }
            }
        } catch {
            print("[STTS] transcriber failed: \(error)")
        }
    }

    // MARK: - Speaking (sentence by sentence, interruptible)

    private func respond(to userText: String) {
        var cleaned = userText
        cleaned.replace(/\.+$/, with: "")
        let response =
            "What you said and what I have heard is...: " + cleaned
            + "\n\n"
            + "Is that correct?\n\n"
            + "Keep talking. I will try to be a good listenner."
        self.transcript_log.append("Bot: \(response)")
        self.pendingSentences = Self.splitSentences(response)
        self.speakNext()
    }

    private static func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(
            in: text.startIndex..<text.endIndex
        ) { range, _ in
            let s = text[range]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty ? [text] : out
    }

    private func speakNext() {
        guard self.is_running else { return }
        guard !self.pendingSentences.isEmpty else {
            self.isSpeaking = false
            self.is_active = true
            return
        }
        let sentence = self.pendingSentences.removeFirst()
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = self.pickVoice()
        utterance.rate = Float(self.speech_rate)
        utterance.pitchMultiplier = Float(self.speech_pitch)
        self.isSpeaking = true
        self.is_active = false
        self.synthesizer.speak(utterance)
    }

    private func pickVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let matching = voices.filter { voice in
            switch self.selected_gender {
            case 1: return voice.gender == .male
            case 2: return voice.gender == .female
            default: return true
            }
        }
        return matching.first { $0.quality == .premium }
            ?? matching.first
    }

    // MARK: - Synthesizer delegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        self.isSpeaking = false
        self.speakNext()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        self.isSpeaking = false
        self.pendingSentences.removeAll()
        self.is_active = true
    }
}
