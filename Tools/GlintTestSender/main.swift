import AppKit
import SwiftUI
import UserNotifications

/// A stand-in for a chat app, so Glint can be tested without waiting for someone to write.
///
/// It posts real macOS notifications and badges its Dock icon the way a messaging app does, on the
/// interval you pick, until you stop it. Its window is titled like a chat ("Sohbet | Burak | …") so
/// Glint's “don't notify for the conversation I'm reading” rule can be tried out too.
@main
struct GlintTestSenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Sohbet", id: "chat") {
            SenderView(sender: delegate.sender)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sender = MessageSender()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = sender
        sender.requestPermission()
        startAutomaticRun()
    }

    /// For measuring from a script: `--auto <messages> <seconds apart> [seconds before the first]` sends
    /// that many messages without anyone clicking, then quits. Glint ignores badges in an app's first
    /// 20 seconds (old notifications syncing in), so a test of the badge wants a delay past that.
    private func startAutomaticRun() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--auto") else { return }
        let count = arguments.count > index + 1 ? Int(arguments[index + 1]) ?? 5 : 5
        let interval = arguments.count > index + 2 ? Double(arguments[index + 2]) ?? 2 : 2
        let delay = arguments.count > index + 3 ? Double(arguments[index + 3]) ?? 0 : 0
        sender.interval = interval
        sender.playSound = false

        var left = count
        let timer = Timer(fire: Date().addingTimeInterval(delay + interval), interval: interval, repeats: true) { [sender] timer in
            MainActor.assumeIsolated {
                guard left > 0 else {
                    timer.invalidate()
                    // Glint takes an app quitting as its messages read and clears their banners, and macOS
                    // writes the records only ~5 s after the last message: stay until those have landed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { NSApp.terminate(nil) }
                    return
                }
                left -= 1
                sender.send()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Sends the messages and keeps the Dock badge in step, like a chat app with unread messages.
@MainActor
@Observable
final class MessageSender: NSObject, UNUserNotificationCenterDelegate {
    var senderName = "Burak"
    /// Seconds between messages.
    var interval: Double = 2
    var playSound = false
    private(set) var running = false
    private(set) var sent = 0
    private(set) var unread = 0
    private(set) var permission = "soruluyor…"

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var nextMessage = 0

    private static let messages = [
        "Müsait misin?",
        "Şunu bir bakabilir misin?",
        "Toplantı 5 dakika sonra başlıyor",
        "Dosyayı gönderdim, haber ver",
        "Bugün için teşekkürler 👍",
        "Akşam görüşelim mi?",
        "Numarayı buldum, iletiyorum",
        "Tamamdır, hallettim",
    ]

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    self?.permission = "hata: \(error.localizedDescription)"
                } else {
                    self?.permission = granted ? "verildi" : "reddedildi — Sistem Ayarları › Bildirimler'den açman gerekiyor"
                }
            }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        send()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    /// One message, as if it had just come in.
    func send() {
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = Self.messages[nextMessage % Self.messages.count]
        content.sound = playSound ? .default : nil
        content.interruptionLevel = .active
        nextMessage += 1
        sent += 1
        unread += 1
        NSApp.dockTile.badgeLabel = "\(unread)"

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.permission = "gönderilemedi: \(error.localizedDescription)" }
        }
    }

    /// Reading the messages in the app: the badge goes, which is Glint's sign that they're read.
    func markRead() {
        unread = 0
        NSApp.dockTile.badgeLabel = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Show the banner even while this app is in front, so the test doesn't depend on which window
    /// is focused.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

struct SenderView: View {
    @Bindable var sender: MessageSender

    var body: some View {
        Form {
            Section("Mesaj") {
                TextField("Gönderen", text: $sender.senderName)
                Picker("Aralık", selection: $sender.interval) {
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0, 30.0], id: \.self) {
                        Text("\(Int($0)) saniyede bir").tag($0)
                    }
                }
                .disabled(sender.running)
                Toggle("Bildirim sesi çal", isOn: $sender.playSound)
            }

            Section("Test") {
                HStack {
                    Button(sender.running ? "Testi Durdur" : "Testi Başlat") {
                        sender.running ? sender.stop() : sender.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(sender.running ? .red : .accentColor)

                    Button("Tek mesaj gönder", action: sender.send)
                        .disabled(sender.running)

                    Spacer()

                    Button("Okundu say", action: sender.markRead)
                        .disabled(sender.unread == 0)
                }
                LabeledContent("Gönderilen", value: "\(sender.sent)")
                LabeledContent("Okunmamış (rozet)", value: "\(sender.unread)")
                LabeledContent("Bildirim izni", value: sender.permission)
            }

            Section {
                Text("Bu pencere “Sohbet | \(sender.senderName) | Glint Test” başlığını taşır; Glint önde olan uygulamanın açık sohbetini bu başlıktan okur. Pencereyi öne alıp test edersen o kişiden gelen bildirimler bastırılır, arkaya alırsan normal bildirilir.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .navigationTitle("Sohbet | \(sender.senderName) | Glint Test")
    }
}
