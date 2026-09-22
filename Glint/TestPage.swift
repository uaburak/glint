import SwiftUI

// MARK: - Test

/// Sends made-up notifications to try the banners out: stacks from several apps, one long stack, a
/// short and a long banner. They arrive a moment apart, with the current position and style, and
/// without sound, glow or alarm.
struct TestPage: View {
    let controller: AlarmController
    @AppStorage(Pref.notifyStyle) private var styleName = NotifyStyle.full.rawValue
    @AppStorage(Pref.notifyBannerPosition) private var positionName = BannerPosition.topRight.rawValue

    /// Time between two notifications of a burst, long enough to watch each one land.
    private static let interval: TimeInterval = 0.3

    private var style: NotifyStyle { NotifyStyle(rawValue: styleName) ?? .full }
    private var position: BannerPosition { BannerPosition(rawValue: positionName) ?? .topRight }

    var body: some View {
        Form {
            Section {
                Hint("Bildirimler şu anki ayarlarla gelir: \(position.title) konumunda, “\(style.title)” stilinde. Ses, ışıma ve alarm çalmaz.")
                if !style.showsMessage {
                    Label("Görünüm Ayarları'nda “Mesaj Nerede Görünsün” Hiçbiri; kart çıkmaz.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("Yığın") {
                TestRow(title: "Karışık yığınlar", detail: "4 uygulamadan 5'er bildirim, sırayla gelir.") {
                    send(apps: 4, perApp: 5)
                }
                TestRow(title: "Tek uygulamadan yığın", detail: "Aynı uygulamadan 5 bildirim.") {
                    send(apps: 1, perApp: 5)
                }
                TestRow(title: "Uzun yığın", detail: "Aynı uygulamadan 12 bildirim; açınca kaydırılır.") {
                    send(apps: 1, perApp: 12)
                }
                TestRow(title: "Kişi bazlı yığınlar", detail: "İlk uygulamada Görkem Alpaslan ve Oğuz Acar'dan 5'er, ikincide iki kişiden 3'er mesaj. Test mesajlarının sohbeti yok; kişiye tıklayınca uygulama açılır.") {
                    sendChats()
                }
            }

            Section("Tek Bildirim") {
                TestRow(title: "Kısa bildirim", detail: "Bir satır başlık, bir satır mesaj.") {
                    guard let app = Self.apps(1).first else { return }
                    controller.showTestBanner(app: app, title: "Ayşe Yılmaz", body: "Akşam görüşelim mi?")
                }
                TestRow(title: "Uzun bildirim", detail: "İki satır başlık, dört satır mesaj.") {
                    guard let app = Self.apps(1).first else { return }
                    controller.showTestBanner(app: app, title: Self.longTitle, body: Self.longBody)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Tüm Bildirimleri Temizle", role: .destructive, action: controller.clearBanners)
                }
            }
        }
    }

    /// The apps take turns, so every stack grows a notification at a time.
    private func send(apps count: Int, perApp: Int) {
        let apps = Self.apps(count)
        var step = 0
        for round in 0..<perApp {
            for (index, app) in apps.enumerated() {
                let sample = Self.sample(app: index, round: round)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * Self.interval) { [controller] in
                    controller.showTestBanner(app: app, title: sample.title, body: sample.body)
                }
                step += 1
            }
        }
    }

    /// Two people per app, taking turns, so each app's stack holds a stack per person.
    private func sendChats() {
        let plan: [(people: [String], perPerson: Int)] = [
            (["Görkem Alpaslan", "Oğuz Acar"], 5),
            (["Elif Şahin", "Can Öztürk"], 3),
        ]
        let apps = Self.apps(plan.count)
        var step = 0
        for round in 0..<(plan.map(\.perPerson).max() ?? 0) {
            for (appIndex, app) in apps.enumerated() where round < plan[appIndex].perPerson {
                for (personIndex, person) in plan[appIndex].people.enumerated() {
                    let body = Self.messages[(appIndex * 4 + personIndex * 2 + round) % Self.messages.count]
                    let thread = NotificationThread(id: "test-\(app.id)-\(person)", url: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * Self.interval) { [controller] in
                        controller.showTestBanner(app: app, title: person, body: body, thread: thread)
                    }
                    step += 1
                }
            }
        }
    }

    // MARK: - Samples

    /// The watched apps first, then Glint's other built-in apps (with their fallback icons if they
    /// aren't installed).
    @MainActor
    private static func apps(_ count: Int) -> [WatchedApp] {
        let listed = WatchedApp.listed
        let others = WatchedApp.builtIn.filter { app in !listed.contains { $0.id == app.id } }
        return Array((listed + others).prefix(count))
    }

    private static let senders = ["Ayşe Yılmaz", "Mehmet Kaya", "Proje Ekibi", "Zeynep Demir", "Can Öztürk", "Elif Şahin"]

    private static let messages = [
        "Toplantı 15:00'e alındı, haberin olsun.",
        "Sunumu paylaştım, bakabilir misin?",
        "Akşam görüşelim mi?",
        "Dosyayı gönderdim 👍",
        "Müşteri geri dönüş yaptı, detayları yazıyorum.",
        "Yarın ofiste misin?",
        "Tamamdır, hallettim.",
        "Bütçe tablosunu güncelledim, son sayfada yeni rakamlar var.",
        "Şunu bir kontrol eder misin? Acil değil ama bugün bitirmemiz lazım.",
        "Kahve?",
    ]

    private static func sample(app: Int, round: Int) -> (title: String, body: String) {
        (senders[(app + round) % senders.count], messages[(app * 3 + round) % messages.count])
    }

    private static let longTitle = "Proje Ekibi: yarınki lansman toplantısıyla ilgili önemli bir güncelleme"
    private static let longBody = "Yarınki sunum için slaytları paylaştım, akşama kadar bakabilirsen çok iyi olur. Ayrıca bütçe tablosunu da güncelledim, son sayfada yeni rakamlar var ve toplantı odası da değişti; 3. kattaki büyük salondayız."
}

/// A test with what it sends written under its name, and a button that sends it.
private struct TestRow: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            Button("Gönder", action: action)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
