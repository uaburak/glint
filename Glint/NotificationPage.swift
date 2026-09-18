import AppKit
import SwiftUI

// MARK: - Bildirim Ayarları

/// Glint's notification switch and the default sound for apps without their own.
struct NotificationPage: View {
    let controller: AlarmController
    @AppStorage(Pref.notifyEnabled) private var enabled = true
    @AppStorage(Pref.notifyBanner) private var bannerEnabled = true
    @AppStorage(Pref.notifyBannerPosition) private var bannerPosition = BannerPosition.topRight.rawValue
    @AppStorage(Pref.notifySound) private var sound = "builtin.ding"
    @AppStorage(Pref.notifyVolume) private var volume = 0.6
    @AppStorage(Pref.badgeFallback) private var badgeFallback = true

    private var currentPosition: BannerPosition {
        BannerPosition(rawValue: bannerPosition) ?? .topRight
    }

    var body: some View {
        Form {
            Section {
                Toggle("Yeni bildirimlerde Glint bildirimi göster", isOn: $enabled)
                Hint("Bildirim gelen uygulamanın renginde ekran kenarı ışıması ve ses. Her uygulama kendi sayfasından ayrıca kapatılabilir.")
                Toggle("Mesaj geldiği anda haber ver, içerik gelince göster", isOn: $badgeFallback)
                Hint("Açıkken bildirim anında çentik ve ışımayla duyurulur, metin gelince yüzen bildirime dolar. Kapalıyken yalnızca metin geldiğinde tek bildirim çıkar.")
            }

            Section("Yüzen Bildirim (Banner)") {
                Toggle("Ekranda yüzen bildirim penceresi göster", isOn: $bannerEnabled)

                if bannerEnabled {
                    LabeledContent("Bildirim konumu") {
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack(spacing: 8) {
                                PositionButton(
                                    title: "Üst Sol",
                                    icon: "arrow.up.left",
                                    position: .topLeft,
                                    current: currentPosition
                                ) { select(.topLeft) }

                                PositionButton(
                                    title: "Üst Orta",
                                    icon: "arrow.up",
                                    position: .topCenter,
                                    current: currentPosition
                                ) { select(.topCenter) }

                                PositionButton(
                                    title: "Üst Sağ",
                                    icon: "arrow.up.right",
                                    position: .topRight,
                                    current: currentPosition
                                ) { select(.topRight) }
                            }

                            HStack(spacing: 8) {
                                PositionButton(
                                    title: "Alt Sol",
                                    icon: "arrow.down.left",
                                    position: .bottomLeft,
                                    current: currentPosition
                                ) { select(.bottomLeft) }

                                PositionButton(
                                    title: "Alt Orta",
                                    icon: "arrow.down",
                                    position: .bottomCenter,
                                    current: currentPosition
                                ) { select(.bottomCenter) }

                                PositionButton(
                                    title: "Alt Sağ",
                                    icon: "arrow.down.right",
                                    position: .bottomRight,
                                    current: currentPosition
                                ) { select(.bottomRight) }
                            }

                            if Notch.current != nil {
                                PositionButton(
                                    title: "Çentik",
                                    icon: "macbook",
                                    position: .notch,
                                    current: currentPosition,
                                    width: 226
                                ) { select(.notch) }
                            }
                        }
                    }

                    if currentPosition == .notch {
                        Hint("Bildirim çentiğin altında birkaç saniye görünür, açılmayanlar çentikte bekler. Çentiğin üzerine gelince uygulamaya göre gruplanmış olarak açılır.")
                    }

                    LabeledContent("Mesaj içeriği") {
                        if controller.hasFullDiskAccess {
                            Label("Gösteriliyor", systemImage: "checkmark.circle.fill")
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

                    HStack {
                        Hint("Bildirim geldiğinde seçtiğin ekran konumunda native görünümlü cam kart olarak belirir.")
                        Spacer()
                        Button("Bildirimi Test Et") {
                            controller.testBanner(position: currentPosition)
                        }
                    }
                }
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

    private func select(_ pos: BannerPosition) {
        bannerPosition = pos.rawValue
        controller.testBanner(position: pos)
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

/// How notifications look: the screen-edge glow and the menu bar item.
struct AppearancePage: View {
    let controller: AlarmController
    @AppStorage(Pref.notifyGlow) private var glow = true
    @AppStorage(Pref.notifyGlowIntensity) private var intensity = 0.8
    @AppStorage(Pref.notifyGlowSeconds) private var glowSeconds = 1.0
    @AppStorage(Pref.showMenuBarCount) private var showMenuBarCount = true

    var body: some View {
        Form {
            Section("Ekran Işıması") {
                Toggle("Ekran kenarlarında ışıma efekti", isOn: $glow)
                Group {
                    LabeledContent("Işıma yoğunluğu") {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: $intensity, in: 0.3...1)
                                .frame(width: 180)
                            Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Işıma süresi", selection: $glowSeconds) {
                        ForEach(choices([1, 2, 3, 5, 10], including: glowSeconds).filter { $0 > 0 }, id: \.self) {
                            Text("\(Int($0)) saniye").tag($0)
                        }
                        Divider()
                        Text("Bildirimler okunana kadar").tag(0.0)
                    }
                    HStack {
                        Hint("Işıma rengi her uygulamanın kendi sayfasından seçilir.")
                        Spacer()
                        Button("Önizle") { controller.testNotification() }
                    }
                }
                .disabled(!glow)
            }

            Section("Menü Çubuğu") {
                Toggle("Okunmamış sayısını zil simgesinin yanında göster", isOn: $showMenuBarCount)
            }
        }
    }
}
