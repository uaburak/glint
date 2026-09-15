import SwiftUI

/// Glint's mark: a bell on a purple rounded square (the app has no icon asset yet).
struct GlintIcon: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(hex: "#7B7FF0"), Color(hex: Pref.teamsPurpleHex)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - Hakkında

struct AboutPage: View {
    let controller: AlarmController

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    GlintIcon(size: 88)
                        .padding(.bottom, 4)
                    Text("Glint")
                        .font(.largeTitle.weight(.bold))
                    Text("Sürüm \(version)")
                        .foregroundStyle(.secondary)
                    Text("Seçtiğin uygulamalara yeni bildirim geldiğinde ekran kenarında o uygulamanın renginde ışıma ve ses; bilgisayar başında değilken dikkat çeken bir alarm.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            Section("Durum") {
                LabeledContent("İzleme") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(controller.isPaused ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(controller.isPaused ? "Duraklatıldı" : "İzleniyor")
                    }
                }
                LabeledContent("İzlenen uygulama", value: "\(WatchedApp.listed.count)")
                LabeledContent("Toplam okunmamış", value: "\(controller.unread)")
                LabeledContent("Sen", value: controller.userAway ? "Uzaktasın" : "Bilgisayar başındasın")
                LabeledContent("Son olay", value: controller.lastEvent)
            }
        }
    }
}
