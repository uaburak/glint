import SwiftUI

/// Walks the user through turning off the watched apps' own macOS banners, so a message doesn't
/// show twice: once from Glint and once from macOS. Only “Masaüstü” goes off; Notification Center
/// stays on, since that's where Glint reads the messages from.
struct NativeBannerGuide: View {
    @Environment(\.dismiss) private var dismiss
    /// Apps whose settings were opened from here, ticked in the list.
    @State private var opened: Set<String> = []

    var body: some View {
        let apps = WatchedApp.listed.filter { WatchedAppStore.shared.config(for: $0).enabled }
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                Text("macOS bildirimlerini kapat")
                    .font(.title3.weight(.semibold))
                Text("Uygulamaların kendi bildirimleri de açık kalırsa her mesaj iki kez görünür. Her uygulamanın macOS ayarında yalnızca **Masaüstü**'nün işaretini kaldır.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                OptionThumb(kind: .desktop)
                OptionThumb(kind: .center)
                OptionThumb(kind: .lockScreen)
            }

            Label("Bildirim Merkezi ve simge işareti açık kalsın: Glint mesajları oradan okur.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            appList(apps)

            HStack {
                Spacer()
                Button("Tamam") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private func appList(_ apps: [WatchedApp]) -> some View {
        if apps.isEmpty {
            Text("Uygulama ekledikçe her biri için bunu yap.")
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            AppIcon(app: app, size: 22)
                            Text(app.name)
                            Spacer()
                            if opened.contains(app.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            Button("Ayarları Aç") {
                                app.openNotificationSettings()
                                opened.insert(app.id)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// One of the three places in macOS's notification settings, drawn small, with the tick it should have.
private struct OptionThumb: View {
    enum Kind { case desktop, center, lockScreen }
    let kind: Kind

    private var title: String {
        switch kind {
        case .desktop: "Masaüstü"
        case .center: "Bildirim Merkezi"
        case .lockScreen: "Kilitli Ekran"
        }
    }

    /// Only the desktop banner goes off.
    private var isOn: Bool { kind != .desktop }

    var body: some View {
        VStack(spacing: 6) {
            screen
                .frame(width: 96, height: 60)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isOn ? Color.clear : Color.red, lineWidth: 2)
                }
            Text(title)
                .font(.caption.weight(.medium))
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            Text(isOn ? "Açık kalsın" : "Kapat")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isOn ? Color.secondary : Color.red)
        }
        .frame(width: 110)
    }

    private var screen: some View {
        MiniScreen(desktop: kind != .lockScreen) { _ in
            Color.clear
        }
            .overlay(alignment: .topTrailing) {
                switch kind {
                case .desktop:
                    bar(width: 26).padding(6)
                case .center:
                    VStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { _ in bar(width: 28) }
                    }
                    .padding(6)
                case .lockScreen:
                    bar(width: 22).padding(6)
                }
            }
            .overlay(alignment: .top) {
                if kind == .lockScreen {
                    Text("9:41")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 8)
                }
            }
    }

    private func bar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white.opacity(0.85))
            .frame(width: width, height: 6)
    }
}
