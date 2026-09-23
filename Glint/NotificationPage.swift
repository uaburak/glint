import AppKit
import SwiftUI

// MARK: - Bildirim Ayarları

/// Glint's notification switch and the default sound for apps without their own. Switching it on
/// brings up the guide to the apps' own macOS banners, which would otherwise show every message twice.
struct NotificationPage: View {
    let controller: AlarmController
    @AppStorage(Pref.notifyEnabled) private var enabled = true
    @AppStorage(Pref.notifySound) private var sound = "builtin.ding"
    @AppStorage(Pref.notifyVolume) private var volume = 0.6
    @State private var showingGuide = false

    var body: some View {
        Form {
            Section {
                Toggle("Glint bildirimleri", isOn: $enabled)
                Hint("Işıma, ses ve mesaj kartı. Uygulamalar tek tek de kapatılabilir.")
            }

            Section("Varsayılan Ses") {
                SoundPicker(title: "Bildirim sesi", selection: $sound, preview: preview)
                VolumeRow(title: "Ses seviyesi", value: $volume, onRelease: preview)
                Hint("Kendi sesi seçilmemiş uygulamalar bunu kullanır.")
            }
            .disabled(!enabled)

            Section("macOS Bildirimleri") {
                LabeledContent("Mesajlar iki kez görünmesin") {
                    Button("Nasıl Kapatılır…") { showingGuide = true }
                }
            }
            .disabled(!enabled)
        }
        .onChange(of: sound) { preview() }
        .onChange(of: enabled) { _, isOn in
            if isOn { showingGuide = true }
        }
        .sheet(isPresented: $showingGuide) { NativeBannerGuide() }
    }

    private func preview() {
        AlarmSoundPlayer.notification.playOnce(sound, volume: volume)
    }
}

// MARK: - Görünüm Ayarları

/// How a notification looks: what the screen does (the glow), the ways the notification shows (the
/// notch, a floating card, the menu bar's count), and their settings.
struct AppearancePage: View {
    let controller: AlarmController
    @AppStorage(Pref.notifyEffect) private var effectName = NotifyEffect.glow.rawValue
    @AppStorage(Pref.notifyStyle) private var styleName = NotifyStyle.full.rawValue
    @AppStorage(Pref.notifyGlowIntensity) private var intensity = 0.8
    @AppStorage(Pref.notifyGlowSeconds) private var glowSeconds = 1.0
    @AppStorage(Pref.notifyBannerPosition) private var bannerPosition = BannerPosition.topRight.rawValue
    @AppStorage(Pref.notifyBannerSeconds) private var bannerSeconds = 6.0
    @AppStorage(Pref.notifyPreview) private var previewName = MessagePreview.full.rawValue
    @AppStorage(Pref.showMenuBarCount) private var showMenuBarCount = true
    @AppStorage(Pref.notchScreen) private var notchScreen = NotchScreen.notched.rawValue
    @AppStorage(Pref.notchShowsAllApps) private var notchShowsAllApps = false
    @AppStorage(Pref.notchHidesVirtualWhenEmpty) private var notchHidesVirtualWhenEmpty = true

    private var effect: NotifyEffect { NotifyEffect(rawValue: effectName) ?? .glow }
    private var style: NotifyStyle { NotifyStyle(rawValue: styleName) ?? .full }
    private var currentPosition: BannerPosition { BannerPosition(rawValue: bannerPosition) ?? .topRight }

    var body: some View {
        Form {
            Section("Efekt Stilleri") {
                HStack(alignment: .top, spacing: 8) {
                    NotificationStyleOption(kind: .glow, title: "Işıma", isOn: glowBinding)
                }
                .padding(.vertical, 8)
            }

            if effect == .glow {
                Section("Işıma") {
                    LabeledContent("Yoğunluk") {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: $intensity, in: 0.3...1)
                                .frame(width: 180)
                            Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Süre", selection: $glowSeconds) {
                        ForEach(choices([1, 2, 3, 5, 10], including: glowSeconds).filter { $0 > 0 }, id: \.self) {
                            Text("\(Int($0)) saniye").tag($0)
                        }
                        Divider()
                        Text("Bildirimler okunana kadar").tag(0.0)
                    }
                    HStack {
                        Hint("Renk, uygulamanın kendi sayfasından seçilir.")
                        Spacer()
                        Button("Önizle") { controller.testNotification() }
                    }
                }
            }

            Section("Bildirim Stilleri") {
                HStack(alignment: .top, spacing: 8) {
                    NotificationStyleOption(kind: .notch, title: "Çentik", isOn: placeBinding(notch: true))
                    NotificationStyleOption(kind: .banner, title: "Yüzen Bildirim", isOn: placeBinding(notch: false))
                    NotificationStyleOption(kind: .menuBar, title: "Menü Çubuğu", isOn: $showMenuBarCount)
                }
                .padding(.vertical, 8)
            }

            if style.showsNotch {
                Section("Çentik") {
                    Picker("Simgeler", selection: $notchShowsAllApps) {
                        Text("Son bildirim gelen uygulama").tag(false)
                        Text("Bildirimi olan tüm uygulamalar").tag(true)
                    }
                    Picker("Ekran", selection: $notchScreen) {
                        ForEach(NotchScreen.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if notchScreen == NotchScreen.main.rawValue {
                        Toggle("Bildirim yokken sanal çentiği gizle", isOn: $notchHidesVirtualWhenEmpty)
                        Hint("Ana ekranda çentik yoksa Glint menü çubuğunun ortasına bir çentik çizer.")
                    } else if Notch.current == nil {
                        Hint("Bu ekranlarda çentik yok. Ekran olarak Ana ekran seçilirse Glint bir çentik çizer.")
                    }
                }
            }

            if style.showsBanner {
                Section("Yüzen Bildirim") {
                    // Side by side across the row, growing with the window.
                    HStack(alignment: .top, spacing: 12) { cardPickers }
                        .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var cardPickers: some View {
        PickerWithLabel("Konum") {
            BannerPositionPicker(selection: positionBinding) { controller.testNotification() }
        }
        PickerWithLabel("Süre") {
            BannerDurationPicker(seconds: $bannerSeconds) { controller.testNotification() }
        }
        PickerWithLabel("Bildirim İçeriği") {
            MessagePreviewPicker(selection: previewBinding) { controller.testNotification() }
        }
    }

    private var previewBinding: Binding<MessagePreview> {
        Binding(
            get: { MessagePreview(rawValue: previewName) ?? .full },
            set: { previewName = $0.rawValue }
        )
    }

    private var glowBinding: Binding<Bool> {
        Binding(
            get: { effect == .glow },
            set: { isOn in
                effectName = (isOn ? NotifyEffect.glow : .none).rawValue
                if isOn { controller.testNotification() }
            }
        )
    }

    /// The notch's checkbox or the card's; both off is the style that shows no message.
    private func placeBinding(notch: Bool) -> Binding<Bool> {
        Binding(
            get: { notch ? style.showsNotch : style.showsBanner },
            set: { isOn in
                let updated = notch
                    ? NotifyStyle(notch: isOn, card: style.showsBanner)
                    : NotifyStyle(notch: style.showsNotch, card: isOn)
                styleName = updated.rawValue
                controller.testNotification()
            }
        )
    }

    private var positionBinding: Binding<BannerPosition> {
        Binding(
            get: { currentPosition },
            set: { bannerPosition = $0.rawValue }
        )
    }
}

/// A small picker with its name under it, as macOS names its thumbnails.
private struct PickerWithLabel<Picker: View>: View {
    let title: String
    @ViewBuilder let picker: Picker

    init(_ title: String, @ViewBuilder picker: () -> Picker) {
        self.title = title
        self.picker = picker()
    }

    var body: some View {
        VStack(spacing: 8) {
            picker
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
