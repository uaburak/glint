import SwiftUI

// MARK: - Çentik / Ada Ayarları

/// The notch island: whether notifications go into it, which icons it shows, what it is on screens
/// without a notch, and how it behaves under the pointer and with new notifications.
struct NotchPage: View {
    let controller: AlarmController
    @AppStorage(Pref.notifyStyle) private var styleName = NotifyStyle.full.rawValue
    @AppStorage(Pref.drawnNotch) private var drawnName = DrawnNotch.island.rawValue
    @AppStorage(Pref.notchShowsAllApps) private var showsAllApps = false
    @AppStorage(Pref.notchShowsBadges) private var showsBadges = true
    @AppStorage(Pref.notchHidesVirtualWhenEmpty) private var hidesVirtualWhenEmpty = true
    @AppStorage(Pref.notchHoverDelay) private var hoverDelay = 0.0
    @AppStorage(Pref.notchWaitMinutes) private var waitMinutes = 30.0
    @AppStorage(Pref.notchGrowsOnArrival) private var growsOnArrival = true

    private var style: NotifyStyle { NotifyStyle(rawValue: styleName) ?? .full }
    private var drawn: DrawnNotch { DrawnNotch(rawValue: drawnName) ?? .island }

    var body: some View {
        Form {
            Section {
                Toggle("Bildirimleri çentikte göster", isOn: enabledBinding)
                if drawn == .none, Notch.current == nil {
                    Hint("Bu Mac'te çentik yok. Çentiksiz Ekranlar'dan Çentik ya da Ada seçilirse Glint kendisi çizer.")
                }
            }

            if style.showsNotch {
                Section("Simgeler") {
                    HStack(alignment: .top, spacing: 12) {
                        StyleChoice(card: StyleCard(islandIcons: 1, islandBadges: showsBadges), title: "Son Uygulama", isOn: !showsAllApps) {
                            showsAllApps = false
                        }
                        StyleChoice(card: StyleCard(islandIcons: 3, islandBadges: showsBadges), title: "Tüm Uygulamalar", isOn: showsAllApps) {
                            showsAllApps = true
                        }
                    }
                    .padding(.vertical, 8)
                    Toggle("Sayı rozetlerini göster", isOn: $showsBadges)
                }

                // The MacBook's own screen always keeps its notch; this is for the others.
                Section("Çentiksiz Ekranlar") {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(DrawnNotch.allCases) { option in
                            StyleChoice(
                                card: StyleCard(
                                    symbol: "display",
                                    // An island shows every app's icon.
                                    islandIcons: option == .none ? 0 : option == .island ? 2 : 1,
                                    islandBadges: showsBadges,
                                    islandFloats: option == .island
                                ),
                                title: option.title,
                                isOn: option == drawn
                            ) {
                                drawnName = option.rawValue
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    if drawn != .none {
                        Toggle(drawn == .island ? "Bildirim yokken adayı gizle" : "Bildirim yokken çentiği gizle", isOn: $hidesVirtualWhenEmpty)
                        Hint("Bildirimler imlecin olduğu ekranda açılır.")
                    }
                }

                Section("Davranış") {
                    HStack(alignment: .top, spacing: 12) {
                        PickerWithLabel("Açılma Gecikmesi") {
                            ChoiceListPicker(
                                choices: [(0.0, "Hemen"), (0.2, "0,2 sn"), (0.5, "0,5 sn"), (1.0, "1 sn")],
                                selection: $hoverDelay
                            )
                        }
                        PickerWithLabel("Bekleme Süresi") {
                            ChoiceListPicker(
                                choices: [(15.0, "15 dk"), (30.0, "30 dk"), (60.0, "1 saat"), (0.0, "Okunana kadar")],
                                selection: $waitMinutes
                            )
                        }
                    }
                    .padding(.vertical, 6)
                    Toggle("Bildirim gelince ada büyüsün", isOn: $growsOnArrival)
                }
            }
        }
    }

    /// The notch's part of the notification style; the card's part stays as it is.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { style.showsNotch },
            set: { isOn in
                styleName = NotifyStyle(notch: isOn, card: style.showsBanner).rawValue
                if isOn { controller.testNotification() }
            }
        )
    }
}
