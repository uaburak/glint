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

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    GlintIcon(size: 88)
                        .padding(.bottom, 4)
                    Text("Glint")
                        .font(.largeTitle.weight(.bold))
                    Text("Sürüm \(AppUpdater.shared.currentVersion)")
                        .foregroundStyle(.secondary)
                    Text("Bildirim geldiğinde uygulamanın renginde ışıma ve ses; uzaktayken alarm.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            Section("Sağlık") {
                if controller.healthIssues.isEmpty {
                    Label("Her şey yolunda", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(controller.healthIssues) { issue in
                        HealthIssueRow(issue: issue, controller: controller)
                    }
                }
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
                LabeledContent("İzleme Kaynağı", value: source)
                LabeledContent("Sessiz mod", value: controller.quietReason?.title ?? "Kapalı")
                LabeledContent("Sen", value: controller.userAway ? "Uzaktasın" : "Bilgisayar başındasın")
                LabeledContent("Son olay", value: controller.lastEvent)
            }
        }
    }

    private var source: String {
        guard controller.hasFullDiskAccess else { return "Dock / LaunchServices" }
        return controller.healthIssues.contains(.databaseUnreadable)
            ? "Dock / LaunchServices (veritabanı okunamıyor)"
            : "Sistem SQLite (usernoted)"
    }
}

/// A problem, what it means, and the buttons that fix or hide it.
private struct HealthIssueRow: View {
    let issue: HealthIssue
    let controller: AlarmController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(issue.title)
                    .font(.body.weight(.medium))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Hint(issue.detail)
            HStack {
                Spacer()
                if issue.isDismissible {
                    Button("Yoksay") { controller.dismiss(issue) }
                }
                if let actionTitle = issue.actionTitle {
                    Button(actionTitle) { issue.performAction() }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
