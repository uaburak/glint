import SwiftUI

// MARK: - Odak ve Öncelik

/// When Glint keeps quiet (a macOS Focus, set hours) and which notifications still get through.
struct QuietPage: View {
    let controller: AlarmController
    @AppStorage(Pref.quietDuringFocus) private var quietDuringFocus = true
    @AppStorage(Pref.quietHoursEnabled) private var quietHoursEnabled = false
    @AppStorage(Pref.quietHoursStart) private var quietHoursStart = 22.0 * 60
    @AppStorage(Pref.quietHoursEnd) private var quietHoursEnd = 7.0 * 60
    @AppStorage(Pref.importantKeywords) private var keywords = ""
    @AppStorage(Pref.importantBreaksQuiet) private var importantBreaksQuiet = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Şu anki durum") {
                    HStack(spacing: 6) {
                        Image(systemName: controller.quietReason == nil ? "bell.fill" : "moon.fill")
                            .foregroundStyle(controller.quietReason == nil ? Color.green : Color.indigo)
                        Text(controller.quietReason.map { "Sessiz (\($0.title))" } ?? "Bildirimler sesli")
                    }
                }
                Hint("Sessizken ses, ekran ışıması ve alarm olmaz; yüzen bildirimler yine sessizce gelir ve çentikte bekler.")
            }

            Section("macOS Odak") {
                Toggle("Odak açıkken sessiz ol", isOn: $quietDuringFocus)
                if quietDuringFocus && !controller.hasFullDiskAccess {
                    LabeledContent("Tam Disk Erişimi gerekli") {
                        Button("Ayarları Aç…", action: SystemSettings.openFullDiskAccess)
                    }
                }
                Hint("Rahatsız Etme, Uyku, İş gibi bir Odak elle ya da zamanlamayla açıldığında Glint de sessiz kalır. macOS Odak durumunu korumalı bir dosyada tuttuğu için Tam Disk Erişimi gerekir.")
            }

            Section("Sessiz Saatler") {
                Toggle("Her gün belirli saatlerde sessiz ol", isOn: $quietHoursEnabled)
                Group {
                    DatePicker("Başlangıç", selection: time($quietHoursStart), displayedComponents: .hourAndMinute)
                    DatePicker("Bitiş", selection: time($quietHoursEnd), displayedComponents: .hourAndMinute)
                }
                .disabled(!quietHoursEnabled)
                Hint("Bitiş başlangıçtan erkense sessiz saatler gece yarısını geçer (ör. 22:00–07:00).")
            }

            Section("Önemli Bildirimler") {
                TextField("Önemli kelimeler", text: $keywords, prompt: Text("ör. @Burak, acil, Ahmet Yılmaz"), axis: .vertical)
                    .lineLimit(2...4)
                Toggle("Önemli bildirimler sessiz modu deler", isOn: $importantBreaksQuiet)
                Hint("Başlığında ya da metninde bu kelimelerden biri geçen bildirim önemlidir. Kelimeleri virgülle ya da satır satır ayır; büyük/küçük harf ve aksan fark etmez. Bir uygulamanın sayfasından alarmını yalnızca önemli bildirimlerde çalacak şekilde ayarlayabilirsin. Metin Tam Disk Erişimiyle okunur; metni okunamayan bildirim için alarm yine çalar.")
            }
        }
    }

    /// Today at the time of day `minutes` after midnight.
    private func time(_ minutes: Binding<Double>) -> Binding<Date> {
        Binding(
            get: {
                let value = Int(minutes.wrappedValue)
                return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
        )
    }
}
