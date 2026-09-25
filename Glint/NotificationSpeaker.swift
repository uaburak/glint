import AVFoundation

/// Says who wrote, aloud, in a Turkish voice when the Mac has one. A new notification cuts off the
/// one being read, so a burst of them never becomes a queue to sit through.
@MainActor
final class NotificationSpeaker {
    /// After the notification's own sound, so the two don't talk over each other.
    private static let delay: TimeInterval = 0.5

    private let synthesizer = AVSpeechSynthesizer()
    private lazy var voice = AVSpeechSynthesisVoice(language: "tr-TR")

    func speak(_ text: String, volume: Double) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.volume = Float(min(max(volume, 0), 1))
        utterance.preUtteranceDelay = Self.delay
        synthesizer.speak(utterance)
    }
}
