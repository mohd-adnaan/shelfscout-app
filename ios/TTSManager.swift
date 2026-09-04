import AVFoundation
import Foundation

final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var ttsState = TTSState()

    private let synthesizer = AVSpeechSynthesizer()
    private var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var queue: [SpeechItem] = []
    private var currentItem: SpeechItem?
    /// Utterances still outstanding for `currentItem`. A cue is spoken as one
    /// utterance per sentence, so the item is only finished when the last of
    /// them reports back.
    private var outstandingUtterances: [AVSpeechUtterance] = []

    private enum SpeechPriority: Int {
        case regular = 0
        case priority = 1
        case critical = 2
    }

    private struct SpeechItem: Equatable {
        let text: String
        let priority: SpeechPriority
        let createdAt: Date
        /// How many times this item has been put back after being cancelled
        /// before it spoke. Capped at one so a synthesizer that refuses an
        /// utterance cannot loop.
        var respeakCount: Int = 0
        /// This item cut another one off, and a tone was played to say so.
        /// Buys the tone a beat of silence before the sentence lands on it.
        var announcedAsInterruption: Bool = false
    }

    // ── Interruption tone ──────────────────────────────────────────────────
    //
    // A critical cue cuts the sentence in progress off mid-word. Reviewer,
    // 3 Sep 2026: "walk 4 m toward the next turn in about 1 [interrupt] turn
    // right … it could be confusing to many users without some sort of audio
    // cue to make clear that the distance countdown is being interrupted by
    // the important immediate turn instruction." Without one there is nothing
    // to distinguish a deliberate cut from the app glitching or the speech
    // dropping out — and the whole point of the cut is that what follows
    // matters more than what was being said.
    //
    // Navigation plays no other native sound, so one short blip is
    // unambiguous. Under VoiceOver nothing is needed: announcements there are
    // QUEUED rather than interrupting, so there is no cut to signal.
    private lazy var interruptTonePlayer: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "bip", withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            NSLog("⚠️ [TTS] bip.wav unavailable — interruptions will not be signalled")
            return nil
        }
        player.volume = 0.6
        player.prepareToPlay()
        return player
    }()
    /// Silence in front of an interrupting cue, so the tone is heard as its own
    /// event rather than under the first syllable.
    private let interruptToneLeadSeconds: TimeInterval = 0.32

    /// True once AVSpeechSynthesizer reports that the current item actually
    /// began. An item cancelled before this is an item nobody heard.
    private var currentItemDidBegin = false
    /// True once any utterance of the current item ran to its natural end.
    /// A cue is spoken as one utterance per sentence, and a multi-sentence cue
    /// whose tail is cut still reached the user — so this is what
    /// `lastCompletedText` is published from, not the fate of the last
    /// utterance alone.
    private var currentItemDidComplete = false

    /// Silence inserted at a sentence boundary inside one cue.
    ///
    /// AVSpeechSynthesizer runs a sentence boundary almost straight into the
    /// next sentence when both sit in a single utterance. That is how "Beer is
    /// 22 meters away. 2 meters toward the next turn." reached a reviewer on 15
    /// Aug 2026 as one breathless run of two numbers — his note asked for a
    /// pause in exactly this position. Speaking each sentence as its own
    /// utterance puts a real gap there, which is also the beat a listener needs
    /// to tell a summary from the instruction that follows it.
    private let interSentencePauseSeconds: TimeInterval = 0.35

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
        currentItemDidBegin = false
        currentItemDidComplete = false
        outstandingUtterances.removeAll()
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

        switch priority {
        case .critical:
            queue.removeAll()
            let isCuttingSomeoneOff = currentItem != nil && currentItem?.priority != .critical
            var queued = item
            queued.announcedAsInterruption = isCuttingSomeoneOff
            queue.insert(queued, at: 0)
            if isCuttingSomeoneOff {
                // Say that a cut is happening BEFORE it happens, so the
                // half-finished sentence reads as interrupted rather than
                // broken. See `interruptTonePlayer`.
                playInterruptTone()
                // Cut the current cue short and let the cancellation callback
                // start this one; speaking it from here would overlap.
                synthesizer.stopSpeaking(at: .word)
                return
            }
        case .priority:
            queue.removeAll { $0.priority != .critical }
            let insertIndex = queue.firstIndex { $0.priority.rawValue < priority.rawValue } ?? queue.endIndex
            queue.insert(item, at: insertIndex)
        case .regular:
            queue.append(item)
        }
        speakNextIfNeeded()
    }

    private func playInterruptTone() {
        guard ttsState.isEnabled, let player = interruptTonePlayer else { return }
        player.currentTime = 0
        player.play()
    }

    private func speakNextIfNeeded() {
        guard currentItem == nil else { return }
        let now = Date()
        queue.removeAll { now.timeIntervalSince($0.createdAt) > 12 && $0.priority != .critical }
        guard let next = queue.first else {
            ttsState.isSpeaking = false
            return
        }
        // AVSpeechSynthesizer keeps reporting `isSpeaking` for a moment after it
        // has cancelled the utterance whose callback brought us here. This guard
        // used to RETURN on that, which stranded the queued cue: nothing calls
        // back in again, so it sat there until some later, unrelated enqueue
        // happened to find it — and a turn instruction that arrives after the
        // turn is worse than one that never arrives. One-cue-at-a-time is
        // already enforced by `currentItem`, so wait a beat and retry instead of
        // dropping the work on the floor.
        guard !synthesizer.isSpeaking else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.speakNextIfNeeded()
            }
            return
        }
        queue.removeFirst()
        speak(next)
    }

    private func speak(_ item: SpeechItem) {
        currentItem = item
        let parts = Self.sentences(of: item.text)
        let utterances = parts.enumerated().map { index, sentence -> AVSpeechUtterance in
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.rate = speechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            // Resolved per utterance, not cached: the user can switch language
            // from Settings while a route is active.
            utterance.voice = AVSpeechSynthesisVoice(language: AppLocale.current.speechLocale)
            if index < parts.count - 1 {
                utterance.postUtteranceDelay = interSentencePauseSeconds
            }
            if index == 0, item.announcedAsInterruption {
                utterance.preUtteranceDelay = interruptToneLeadSeconds
            }
            return utterance
        }
        outstandingUtterances = utterances
        currentItemDidBegin = false
        currentItemDidComplete = false
        ttsState.lastSpokenText = item.text
        ttsState.lastSpeechTime = Date()
        ttsState.isSpeaking = true
        utterances.forEach { synthesizer.speak($0) }
    }

    /// Splits a cue into the sentences it should be spoken as.
    ///
    /// Deliberately conservative: only a full stop, question mark or
    /// exclamation FOLLOWED BY WHITESPACE ends a sentence. A decimal point has
    /// a digit after it, so "1.5 meters" stays whole, and a cue with no
    /// internal boundary comes back as itself.
    private static func sentences(of text: String) -> [String] {
        let characters = Array(text)
        var parts: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard character == "." || character == "!" || character == "?",
                  index + 1 < characters.count,
                  characters[index + 1].isWhitespace else {
                continue
            }
            let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { parts.append(sentence) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [text] : parts
    }

    private func finish(_ utterance: AVSpeechUtterance, completed: Bool) {
        if completed { currentItemDidComplete = true }
        outstandingUtterances.removeAll { $0 === utterance }
        guard outstandingUtterances.isEmpty else { return }

        let finished = currentItem
        currentItem = nil

        if currentItemDidComplete, let finished {
            ttsState.lastCompletedText = finished.text
        } else if let finished, !currentItemDidBegin {
            // Cancelled before a single word of it was spoken.
            //
            // Usually that is deliberate: a critical cue preempts a lower one,
            // and the preempted cue is supposed to die. But `stopSpeaking` is
            // asynchronous and cancels the whole queue, so an utterance handed
            // to the synthesizer while a stop is still draining gets taken with
            // it — and the thing most likely to be in that position is the
            // critical cue that ordered the stop. That is how "Arrived at 437,
            // on your right" was cut off a syllable in on 3 Sep 2026, after the
            // AR screen had already been taught to wait for it: it satisfied
            // "started, and no longer speaking" without ever being audible.
            //
            // So: put it back, but only when nothing at least as important is
            // waiting. If something is, this cancellation was the preemption
            // working as designed.
            let outrankedByQueue = queue.contains { $0.priority.rawValue >= finished.priority.rawValue }
            if !outrankedByQueue, finished.respeakCount < 1 {
                var retry = finished
                retry.respeakCount += 1
                queue.insert(retry, at: 0)
            }
        }

        currentItemDidBegin = false
        currentItemDidComplete = false
        speakNextIfNeeded()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        currentItemDidBegin = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance, completed: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance, completed: false)
    }
}
