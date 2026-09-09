import Foundation
import Speech
import AVFoundation

/// 语音管理：按住说话识别（系统 SFSpeechRecognizer 中文）+ 语音回复（AVSpeechSynthesizer）
@MainActor
final class SpeechManager: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var partialText = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var synthesizer = AVSpeechSynthesizer()
    var onResult: ((String) -> Void)?
    var onPartial: ((String) -> Void)?

    func requestPermission() {
        #if os(iOS)
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        #endif
    }

    func isAvailable() -> Bool {
        recognizer?.isAvailable ?? false
    }

    /// 开始录音识别（按住时）
    func startListening() {
        #if os(iOS)
        guard isAvailable(), !isListening else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onResult?("⚠️ 麦克风启动失败")
            return
        }
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request, let recognizer, recognizer.isAvailable else { return }
        request.shouldReportPartialResults = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.partialText = text
                self.onPartial?(text)  // 实时推识别文字
            }
            if error != nil { self.stopListening(finish: true) }
        }
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            self.request?.append(buffer)
        }
        audioEngine.prepare()
        try? audioEngine.start()
        isListening = true
        #endif
    }

    /// 停止识别（松开时）→ 返回识别结果
    func stopListening(finish: Bool = true) {
        #if os(iOS)
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isListening = false
        if finish {
            let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
            partialText = ""
            if !text.isEmpty { onResult?(text) }
        }
        task?.cancel()
        task = nil
        request = nil
        #endif
    }

    /// 语音回复（星桥回复到达时播报）
    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        // 去除 emoji/标记，简短播报
        let clean = text.replacingOccurrences(of: "✅", with: "").replacingOccurrences(of: "🎉", with: "")
            .replacingOccurrences(of: "⚠️", with: "注意").replacingOccurrences(of: "⭐", with: "")
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }
}
