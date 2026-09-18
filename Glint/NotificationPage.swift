import AppKit
import SwiftUI

// MARK: - Bildirim Ayarları

/// Glint's notification switch and the default sound for apps without their own.
struct NotificationPage: View {
    let controller: AlarmController
    @AppStorage(Pref.notifyEnabled) private var enabled = true
    @AppStorage(Pref.notifySound) private var sound = "builtin.ding"
    @AppStorage(Pref.notifyVolume) private var volume = 0.6

    var body: some View {
        Form {
            Section {
                Toggle("Yeni bildirimlerde Glint bildirimi göster", isOn: $enabled)
                Hint("Bildirim gelen uygulamanın renginde ekran kenarı ışıması, çentikte simgesi ve yüzen bildirim — hepsi birlikte. Her uygulama kendi sayfasından ayrıca kapatılabilir.")
            }

            Section("Mesaj İçeriği") {
                LabeledContent("Bildirim metinleri") {
                    if controller.hasFullDiskAccess {
                        Label("Okunuyor", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Tam Disk Erişimi Ver…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Hint("İzin verildiğinde bildirimler başlık ve metniyle gelir; verilmezse yalnızca okunmamış sayısı gösterilir.")
            }
            .disabled(!enabled)

            Section("Varsayılan Ses") {
                SoundPicker(title: "Bildirim sesi", selection: $sound, preview: preview)
                VolumeRow(title: "Ses seviyesi", value: $volume, onRelease: preview)
                Hint("Kendi sesi seçilmemiş uygulamalar bunu kullanır. Mac sessizdeyken duyulmaz.")
            }
            .disabled(!enabled)

            Section("Uygulamaların Kendi Bildirimleri") {
                Hint("Aynı bildirimi iki kez görmemek için uygulamanın sayfasındaki “Bildirim Ayarlarını Aç…” düğmesinden “Masaüstü”nün işaretini kaldır. “Bildirim Merkezi” ve “Uygulama simgesi işareti” açık kalmalı.")
            }
        }
        .onChange(of: sound) { preview() }
    }

    private func preview() {
        AlarmSoundPlayer.notification.playOnce(sound, volume: volume)
    }
}

private struct PositionButton: View {
    let title: String
    let icon: String
    let position: BannerPosition
    let current: BannerPosition
    var width: CGFloat = 70
    let onSelect: () -> Void

    var isSelected: Bool {
        position == current
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                Text(title)
                    .font(.system(size: 10.5, weight: isSelected ? .bold : .regular))
            }
            .frame(width: width, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Görünüm Ayarları

/// How a notification looks: what the screen does, where the message shows, and their settings.
struct AppearancePage: View {
    let controller: AlarmController
    @AppStorage(Pref.notifyEffect) private var effectName = NotifyEffect.glow.rawValue
    @AppStorage(Pref.notifyStyle) private var styleName = NotifyStyle.full.rawValue
    @AppStorage(Pref.notifyGlowIntensity) private var intensity = 0.8
    @AppStorage(Pref.notifyGlowSeconds) private var glowSeconds = 1.0
    @AppStorage(Pref.notifyBannerPosition) private var bannerPosition = BannerPosition.topRight.rawValue
    @AppStorage(Pref.showMenuBarCount) private var showMenuBarCount = true

    private var effect: NotifyEffect { NotifyEffect(rawValue: effectName) ?? .glow }
    private var style: NotifyStyle { NotifyStyle(rawValue: styleName) ?? .full }
    private var currentPosition: BannerPosition { BannerPosition(rawValue: bannerPosition) ?? .topRight }

    var body: some View {
        Form {
            Section("Bildirim Efekti") {
                ForEach(NotifyEffect.allCases) { option in
                    ChoiceRow(
                        title: option.title, detail: option.detail, symbol: option.symbol,
                        isSelected: option == effect
                    ) {
                        effectName = option.rawValue
                        controller.testNotification()
                    }
                }
            }

            if effect != .none {
                Section("Efekt Ayarları") {
                    LabeledContent("Efekt yoğunluğu") {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: $intensity, in: 0.3...1)
                                .frame(width: 180)
                            Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                        }
                    }
                    if effect.canPersist {
                        Picker("Efekt süresi", selection: $glowSeconds) {
                            ForEach(choices([1, 2, 3, 5, 10], including: glowSeconds).filter { $0 > 0 }, id: \.self) {
                                Text("\(Int($0)) saniye").tag($0)
                            }
                            Divider()
                            Text("Bildirimler okunana kadar").tag(0.0)
                        }
                    }
                    HStack {
                        Hint(hint)
                        Spacer()
                        Button("Önizle") { controller.testNotification() }
                    }
                }
            }

            Section("Mesaj Nerede Görünsün") {
                ForEach(NotifyStyle.allCases) { option in
                    ChoiceRow(
                        title: option.title, detail: option.detail, symbol: option.symbol,
                        isSelected: option == style
                    ) {
                        styleName = option.rawValue
                        controller.testNotification()
                    }
                }
                if Notch.current == nil, style.showsNotch {
                    Hint("Bu Mac'te çentik yok; çentik seçenekleri yalnızca menü çubuğundaki sayıyı gösterir.")
                }
            }

            if style.showsBanner {
                Section("Yüzen Bildirim") {
                    LabeledContent("Kartın konumu") {
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack(spacing: 8) {
                                PositionButton(title: "Üst Sol", icon: "arrow.up.left", position: .topLeft, current: currentPosition) { select(.topLeft) }
                                PositionButton(title: "Üst Orta", icon: "arrow.up", position: .topCenter, current: currentPosition) { select(.topCenter) }
                                PositionButton(title: "Üst Sağ", icon: "arrow.up.right", position: .topRight, current: currentPosition) { select(.topRight) }
                            }
                            HStack(spacing: 8) {
                                PositionButton(title: "Alt Sol", icon: "arrow.down.left", position: .bottomLeft, current: currentPosition) { select(.bottomLeft) }
                                PositionButton(title: "Alt Orta", icon: "arrow.down", position: .bottomCenter, current: currentPosition) { select(.bottomCenter) }
                                PositionButton(title: "Alt Sağ", icon: "arrow.down.right", position: .bottomRight, current: currentPosition) { select(.bottomRight) }
                            }
                            if Notch.current != nil {
                                PositionButton(title: "Çentik", icon: "macbook", position: .notch, current: currentPosition, width: 226) { select(.notch) }
                            }
                        }
                    }
                }
            }

            Section("Menü Çubuğu") {
                Toggle("Okunmamış sayısını zil simgesinin yanında göster", isOn: $showMenuBarCount)
            }
        }
    }

    private var hint: String {
        effect == .none ? "" : "Efektin rengi her uygulamanın kendi sayfasından seçilir."
    }

    private func select(_ position: BannerPosition) {
        bannerPosition = position.rawValue
        controller.testNotification()
    }
}

/// One choice in a list, with what it does written under its name.
private struct ChoiceRow: View {
    let title: String
    let detail: String
    let symbol: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.secondary))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
