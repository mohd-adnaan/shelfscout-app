import AVFoundation
import Foundation

final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var ttsState = TTSState()

    private let synthesizer = AVSpeechSynthesizer()
    private var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var queue: [SpeechItem] = []
    private var currentItem: SpeechItem?

    private enum SpeechPriority: Int {
        case regular = 0
        case priority = 1
        case critical = 2
    }

    private struct SpeechItem: Equatable {
        let text: String
        let priority: SpeechPriority
        let createdAt: Date
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func setSpeechRate(_ rate: Double?) {
        guard let rate else { return }
        let clamped = max(0.1, min(1.0, rate))
        speechRate = Float(0.35 + (clamped * 0.25))
    }

    func speak(_ text: String) {
        enqueue(text, priority: .regular)
    }

    func speakPriority(_ text: String) {
        enqueue(text, priority: .priority)
    }

    func speakCritical(_ text: String) {
        enqueue(text, priority: .critical)
    }

    func stop() {
        queue.removeAll()
        currentItem = nil
        synthesizer.stopSpeaking(at: .immediate)
        ttsState.isSpeaking = false
    }

    private func enqueue(_ text: String, priority: SpeechPriority) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ttsState.isEnabled else { return }
        guard currentItem?.text != trimmed,
              queue.contains(where: { $0.text == trimmed }) == false else {
            return
        }

        let item = SpeechItem(text: trimmed, priority: priority, createdAt: Date())

        guard currentItem != nil || synthesizer.isSpeaking else {
            speak(item)
            return
        }

        switch priority {
        case .critical:
            queue.removeAll()
            queue.insert(item, at: 0)
            if currentItem?.priority != .critical {
                synthesizer.stopSpeaking(at: .word)
            }
        case .priority:
            queue.removeAll { $0.priority != .critical }
            let insertIndex = queue.firstIndex { $0.priority.rawValue < priority.rawValue } ?? queue.endIndex
            queue.insert(item, at: insertIndex)
        case .regular:
            queue.append(item)
        }
    }

    private func speakNextIfNeeded() {
        guard currentItem == nil, synthesizer.isSpeaking == false else { return }
        let now = Date()
        queue.removeAll { now.timeIntervalSince($0.createdAt) > 12 && $0.priority != .critical }
        guard !queue.isEmpty else {
            ttsState.isSpeaking = false
            return
        }
        speak(queue.removeFirst())
    }

    private func speak(_ item: SpeechItem) {
        currentItem = item
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.rate = speechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        ttsState.lastSpokenText = item.text
        ttsState.lastSpeechTime = Date()
        ttsState.isSpeaking = true
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        currentItem = nil
        speakNextIfNeeded()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        currentItem = nil
        speakNextIfNeeded()
    }
}
