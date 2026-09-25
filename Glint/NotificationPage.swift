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

/// How a notification looks: what the screen does (a glow, a dimming), the ways the notification
/// shows (a floating card, the menu bar's count, a bubble by the pointer, a voice), and their
/// settings. The notch has a page of its own.
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
    @AppStorage(Pref.notifyNearPointer) private var nearPointer = false
    @AppStorage(Pref.notifySpeaks) private var speaks = false
    @AppStorage(Pref.speechContent) private var speechContent = SpeechContent.sender.rawValue

    private var effect: NotifyEffect { NotifyEffect(rawValue: effectName) ?? .glow }
    private var style: NotifyStyle { NotifyStyle(rawValue: styleName) ?? .full }
    private var currentPosition: BannerPosition { BannerPosition(rawValue: bannerPosition) ?? .topRight }

    var body: some View {
        Form {
            Section("Efekt Stilleri") {
                HStack(alignment: .top, spacing: 12) {
                    ForEach([NotifyEffect.glow, .dim, .none]) { option in
                        // Each effect with a notification's card at the top, the way it looks when one comes.
                        StyleChoice(card: StyleCard(effect: option, content: .banner, symbol: option == .none ? "nosign" : nil), title: option.title, isOn: option == effect) {
                            guard option != effect else { return }
                            effectName = option.rawValue
                            if option != .none { controller.testNotification() }
                        }
                    }
                }
                .padding(.vertical, 8)

                // The chosen effect's settings, right under it.
                if effect != .none {
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
                }
            }

            Section("Bildirim Stilleri") {
                HStack(alignment: .top, spacing: 12) {
                    toggle(StyleCard(content: .banner), "Yüzen Bildirim", placeBinding(notch: false))
                    toggle(StyleCard(content: .menuBar), "Menü Çubuğu", $showMenuBarCount)
                    toggle(StyleCard(content: .pointer), "İmleç Yanında", previewing($nearPointer))
                    toggle(StyleCard(symbol: "speaker.wave.2.fill"), "Sesli Okuma", previewing($speaks))
                }
                .padding(.vertical, 8)

                // The settings of the styles that are on, right under them.
                if style.showsBanner {
                    // Side by side across the row, growing with the window.
                    HStack(alignment: .top, spacing: 12) { cardPickers }
                        .padding(.vertical, 6)
                }
                if speaks {
                    Picker("Sesli okuma", selection: $speechContent) {
                        ForEach(SpeechContent.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
            }
        }
    }

    /// A notification style, drawn on its own and on or off by a click on it.
    private func toggle(_ card: StyleCard, _ title: String, _ isOn: Binding<Bool>) -> some View {
        StyleChoice(card: card, title: title, isOn: isOn.wrappedValue) {
            isOn.wrappedValue.toggle()
        }
    }

    /// A style that shows what it does when it's switched on.
    private func previewing(_ isOn: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { isOn.wrappedValue },
            set: { value in
                isOn.wrappedValue = value
                if value { controller.testNotification() }
            }
        )
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

