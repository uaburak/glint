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
                Hint("Uygulamalar sayfasındaki bir uygulamanın Dock simgesindeki sayı arttığında ekran kenarında o uygulamanın renginde ışıma ve bildirim sesi verilir. Her uygulama kendi sayfasından ayrıca kapatılabilir.")
            }

            Section("Varsayılan Ses") {
                SoundPicker(title: "Bildirim sesi", selection: $sound, preview: preview)
                VolumeRow(title: "Ses seviyesi", value: $volume, onRelease: preview)
                Hint("Kendi sesi ya da seviyesi seçilmemiş uygulamalar bunları kullanır. Bildirim sesi Mac'in mevcut ses seviyesine bağlı çalar; Mac sessizdeyse duyulmaz.")
            }
            .disabled(!enabled)

            Section("Uygulamaların Kendi Bildirimleri") {
                Hint("macOS bir uygulamanın başka bir uygulamanın bildirimlerini kapatmasına izin vermez. Aynı bildirimi iki kez görmemek için uygulamanın sayfasındaki “Bildirim Ayarlarını Aç…” düğmesiyle uyarı stilini Yok yap. “Uygulama simgesinde işaret göster” açık kalmalı; Glint yeni bildirimleri o sayıdan anlıyor.")
            }
        }
        .onChange(of: sound) { preview() }
    }

    private func preview() {
        AlarmSoundPlayer.notification.playOnce(sound, volume: volume)
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
