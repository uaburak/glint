import AppKit
import AVFoundation

struct AlarmSound: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Built-in synthesized tones plus every sound in /System/Library/Sounds and ~/Library/Sounds.
enum AlarmSoundLibrary {
    static let silentID = "none"
    static let defaultID = "builtin.chime"

    static let builtIn: [AlarmSound] = [
        AlarmSound(id: "builtin.ding", name: "Ding"),
        AlarmSound(id: "builtin.chime", name: "Nazik zil"),
        AlarmSound(id: "builtin.beeps", name: "Bip bip"),
        AlarmSound(id: "builtin.siren", name: "Siren (yoğun)"),
    ]

    /// macOS alert sounds: name → file.
    private static let systemFiles: [String: URL] = {
        let folders = ["/System/Library/Sounds", NSHomeDirectory() + "/Library/Sounds"]
        let extensions: Set = ["aiff", "aif", "caf", "wav", "m4a", "mp3"]
        var files: [String: URL] = [:]
        for folder in folders {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            where extensions.contains((file as NSString).pathExtension.lowercased()) {
                files[(file as NSString).deletingPathExtension] = URL(fileURLWithPath: folder).appendingPathComponent(file)
            }
        }
        return files
    }()

    static let system: [AlarmSound] = systemFiles.keys.sorted().map { AlarmSound(id: "system.\($0)", name: $0) }

    /// Display name of a sound ID, for labels like "Varsayılan (Ding)".
    static func name(of id: String) -> String {
        if id == silentID { return "Sessiz" }
        return (builtIn + system).first { $0.id == id }?.name ?? id
    }

    static func makeSound(_ id: String) -> NSSound? {
        switch id {
        case "builtin.ding": NSSound(data: Tone.ding)
        case "builtin.chime": NSSound(data: Tone.chime)
        case "builtin.beeps": NSSound(data: Tone.beeps)
        case "builtin.siren": NSSound(data: Tone.siren)
        case let id where id.hasPrefix("system."): NSSound(named: String(id.dropFirst("system.".count)))
        default: nil
        }
    }

    /// A preloadable player for short sounds that must start instantly (notifications).
    static func makePlayer(_ id: String) -> AVAudioPlayer? {
        switch id {
        case "builtin.ding": try? AVAudioPlayer(data: Tone.ding)
        case "builtin.chime": try? AVAudioPlayer(data: Tone.chime)
        case "builtin.beeps": try? AVAudioPlayer(data: Tone.beeps)
        case "builtin.siren": try? AVAudioPlayer(data: Tone.siren)
        case let id where id.hasPrefix("system."):
            systemFiles[String(id.dropFirst("system.".count))].flatMap { try? AVAudioPlayer(contentsOf: $0) }
        default: nil
        }
    }

    /// Built-in tones already end with a pause; short system sounds get one added between repeats.
    static func repeatGap(_ id: String) -> TimeInterval {
        id.hasPrefix("builtin.") ? 0 : 0.6
    }
}

/// Plays the alarm sound on repeat for a while, optionally setting the Mac's output
/// volume (and unmuting) for the duration and restoring it afterwards.
@MainActor
final class AlarmSoundPlayer {
    static let shared = AlarmSoundPlayer()
    /// Separate player for message notifications, so they never cut off the alarm.
    static let notification = AlarmSoundPlayer()

    private var quickPlayers: [String: AVAudioPlayer] = [:]

    /// Loads a short sound ahead of time so `playOnce` starts without a delay.
    func prepare(_ id: String) {
        guard quickPlayers[id] == nil, let player = AlarmSoundLibrary.makePlayer(id) else { return }
        player.prepareToPlay()
        quickPlayers[id] = player
    }

    /// Plays a sound once, right away, at `volume` relative to the Mac's current output volume.
    func playOnce(_ id: String, volume: Double) {
        prepare(id)
        guard let player = quickPlayers[id] else { return }
        player.volume = Float(volume)
        player.currentTime = 0
        if !player.isPlaying { player.play() }
    }

    private var sound: NSSound?
    private var repeatTimer: Timer?
    private var stopWork: DispatchWorkItem?
    private var savedVolume: (volume: Int, muted: Bool)?

    func play(_ id: String, volume: Double, overrideSystemVolume: Bool, duration: TimeInterval) {
        stop()
        guard let sound = AlarmSoundLibrary.makeSound(id) else { return }

        if overrideSystemVolume, let current = SystemVolume.get() {
            savedVolume = current
            SystemVolume.set(volume: Int((volume * 100).rounded()), muted: false)
            sound.volume = 1
        } else {
            sound.volume = Float(volume)
        }
        self.sound = sound
        sound.play()

        let interval = max(sound.duration, 0.3) + AlarmSoundLibrary.repeatGap(id)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sound?.stop()
                self?.sound?.play()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer

        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        sound?.stop()
        sound = nil
        if let saved = savedVolume {
            SystemVolume.set(volume: saved.volume, muted: saved.muted)
            savedVolume = nil
        }
    }
}

/// Synthesized 16-bit mono WAV tones.
private enum Tone {
    static let rate = 44_100.0

    /// A single soft bell note — short enough for a notification.
    static let ding = render(seconds: 1.0) { t in
        bell(1318.5, at: 0, t) * 1.2
    }

    /// Two soft bell notes (E6 → C6), then a pause.
    static let chime = render(seconds: 1.6) { t in
        bell(1318.5, at: 0, t) + bell(1046.5, at: 0.42, t)
    }

    /// Three short sine beeps, like a quiet alarm clock.
    static let beeps = render(seconds: 1.1) { t in
        let index = Int(t / 0.18)
        let local = t - Double(index) * 0.18
        guard index < 3, local < 0.1 else { return 0 }
        return sin(2 * .pi * 988 * t) * 0.4 * min(1, local / 0.005, (0.1 - local) / 0.01)
    }

    /// Harsh up/down square-wave sweep.
    static let siren: Data = {
        var phase = 0.0
        return render(seconds: 1) { t in
            let frequency = 650 + 900 * (t < 0.5 ? t * 2 : (1 - t) * 2)
            phase += 2 * .pi * frequency / rate
            return sin(phase) >= 0 ? 0.7 : -0.7
        }
    }()

    private static func bell(_ frequency: Double, at start: Double, _ t: Double) -> Double {
        let x = t - start
        guard x >= 0 else { return 0 }
        let envelope = exp(-x * 3.5) * min(1, x / 0.004)
        let partials = sin(2 * .pi * frequency * x) * 0.7
            + sin(2 * .pi * frequency * 2 * x) * 0.2
            + sin(2 * .pi * frequency * 3 * x) * 0.1
        return partials * envelope * 0.45
    }

    private static func render(seconds: Double, _ sample: (Double) -> Double) -> Data {
        let count = Int(seconds * rate)
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let value = max(-1, min(1, sample(Double(i) / rate)))
            withUnsafeBytes(of: Int16(value * Double(Int16.max)).littleEndian) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1))           // PCM, mono
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
