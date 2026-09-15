import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An app's own icon, or its fallback symbol when the app isn't installed.
struct AppIcon: View {
    let app: WatchedApp
    var size: CGFloat = 28

    var body: some View {
        if let icon = app.appIcon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: app.fallbackIconName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(hex: app.defaultColorHex))
                .padding(size * 0.12)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Uygulamalar

/// The watched apps, each opening its own page, and a button to add more.
struct AppsPage: View {
    let controller: AlarmController
    let open: (WatchedApp) -> Void

    var body: some View {
        let apps = WatchedApp.listed
        Form {
            Section {
                if apps.isEmpty {
                    Text("Henüz izlenen uygulama yok.")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps) { app in
                    AppRow(app: app, controller: controller) { open(app) }
                }
            } footer: {
                HStack {
                    Spacer()
                    AddAppMenu(added: open)
                }
            }

            Section {
                Hint("Glint, Dock simgesinde okunmamış sayısı (rozet) gösteren her uygulamanın yeni bildirimlerini algılar. Microsoft Teams, WhatsApp, Telegram, Slack, Discord ve Signal yüklüyse kendiliğinden listelenir.")
            }
        }
    }
}

private struct AppRow: View {
    let app: WatchedApp
    let controller: AlarmController
    let action: () -> Void

    var body: some View {
        let config = WatchedAppStore.shared.config(for: app)
        let unread = controller.appStatuses[app.id]?.unread ?? 0
        Button(action: action) {
            HStack(spacing: 10) {
                AppIcon(app: app, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                    Text(summary(config))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if unread > 0 {
                    Text("\(unread)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                Circle()
                    .fill(Color(hex: config.glowColorHex))
                    .frame(width: 10, height: 10)
                    .opacity(config.enabled ? 1 : 0.3)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func summary(_ config: WatchedAppConfig) -> String {
        let running = controller.appStatuses[app.id]?.running ?? (app.runningApp != nil)
        return [
            config.enabled ? "Bildirim açık" : "Bildirim kapalı",
            config.alarmEnabled ? "Alarm açık" : "Alarm kapalı",
            running ? nil : "Uygulama kapalı",
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

/// "Uygulama Ekle" pop-up: a running app, or any app picked from /Applications.
private struct AddAppMenu: View {
    let added: (WatchedApp) -> Void

    var body: some View {
        Menu {
            let running = addableRunningApps
            if !running.isEmpty {
                Section("Açık Uygulamalar") {
                    ForEach(running, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") { add(app.bundleURL) }
                    }
                }
                Divider()
            }
            Button("Başka Bir Uygulama Seç…", action: chooseApp)
        } label: {
            Label("Uygulama Ekle", systemImage: "plus")
        }
        .fixedSize()
    }

    /// Running apps with a Dock icon that aren't watched yet.
    private var addableRunningApps: [NSRunningApplication] {
        let watched = Set(WatchedApp.all.flatMap(\.bundleIDs))
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, app.bundleURL != nil,
                      let id = app.bundleIdentifier else { return false }
                return id != Bundle.main.bundleIdentifier && !watched.contains(id)
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func add(_ url: URL?) {
        guard let url, let app = WatchedAppStore.shared.add(appAt: url) else { return }
        added(app)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ekle"
        panel.message = "Bildirimlerini Glint'ten almak istediğin uygulamayı seç."
        guard panel.runModal() == .OK else { return }
        add(panel.url)
    }
}

// MARK: - Uygulama sayfası

/// One app's own settings: notification and alarm, glow color, sound and volume.
struct AppDetailPage: View {
    let app: WatchedApp
    let controller: AlarmController
    let onRemove: () -> Void

    @AppStorage(Pref.notifySound) private var defaultSound = "builtin.ding"
    @AppStorage(Pref.notifyVolume) private var defaultVolume = 0.6
    @State private var confirmingRemoval = false

    private var store: WatchedAppStore { .shared }
    private var config: WatchedAppConfig { store.config(for: app) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIcon(app: app, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.title3.weight(.semibold))
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uygulamayı Aç") { app.openApplication() }
                        .disabled(!app.isInstalled)
                }
                .padding(.vertical, 4)
            }

            Section("Bildirim") {
                Toggle("Glint bildirimi", isOn: binding(\.enabled))
                Toggle("Uzaktayken alarm çal", isOn: binding(\.alarmEnabled))
                Toggle("Alarmı yalnızca önemli bildirimlerde çal", isOn: binding(\.alarmOnlyImportant))
                    .disabled(!config.alarmEnabled)
                    .help("Önemli kelimeler Odak ve Öncelik sayfasından seçilir.")
                LabeledContent("macOS bildirimleri") {
                    Button("Bildirim Ayarlarını Aç…") { app.openNotificationSettings() }
                }
                Hint("Glint bildirimi yeni bildirimde ekran kenarında ışıma ve ses verir. Alarm, bilgisayar başında değilken tam ekran uyarı gösterir. Aynı bildirimi iki kez görmemek için macOS ayarlarında “Masaüstü” kutusunun işaretini kaldır; “Bildirim Merkezi” ve “Uygulama simgesi işareti” açık kalmalı.")
            }

            Section("Görünüm") {
                LabeledContent("Işıma rengi") {
                    HStack(spacing: 10) {
                        if config.glowColorHex.caseInsensitiveCompare(app.defaultColorHex) != .orderedSame {
                            Button("Varsayılana Dön") {
                                store.update(app) { $0.glowColorHex = app.defaultColorHex }
                            }
                            .buttonStyle(.borderless)
                        }
                        ColorPicker("Işıma rengi", selection: colorBinding, supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
            .disabled(!config.enabled)

            Section("Ses") {
                SoundPicker(
                    title: "Bildirim sesi",
                    selection: soundBinding,
                    defaultName: AlarmSoundLibrary.name(of: defaultSound),
                    preview: preview
                )
                VolumeRow(title: "Ses seviyesi", value: volumeBinding, onRelease: preview)
                if config.volume != nil {
                    HStack {
                        Spacer()
                        Button("Varsayılan seviyeyi kullan (%\(Int((defaultVolume * 100).rounded())))") {
                            store.update(app) { $0.volume = nil }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Hint("Varsayılan ses ve seviye Bildirim Ayarları sayfasından değiştirilir.")
            }
            .disabled(!config.enabled)

            Section {
                HStack {
                    Button {
                        controller.testNotification(for: app)
                    } label: {
                        Label("Bildirimi Test Et", systemImage: "sparkles")
                    }
                    Button {
                        controller.testAlarm(for: app)
                    } label: {
                        Label("Alarmı Test Et", systemImage: "alarm.waves.left.and.right")
                    }
                    Spacer()
                    if !app.isBuiltIn {
                        Button("Listeden Kaldır…", role: .destructive) { confirmingRemoval = true }
                    }
                }
            }
        }
        .onChange(of: config.soundID) { preview() }
        .confirmationDialog("\(app.name) listeden kaldırılsın mı?", isPresented: $confirmingRemoval) {
            Button("Kaldır", role: .destructive) {
                store.remove(app)
                onRemove()
            }
        } message: {
            Text("Glint bu uygulamanın bildirimlerini göstermeyi bırakır. Uygulamanın kendisi silinmez.")
        }
    }

    private var statusText: String {
        guard app.isInstalled else { return "Yüklü değil" }
        let running = controller.appStatuses[app.id]?.running ?? (app.runningApp != nil)
        guard running else { return "Kapalı" }
        let unread = controller.appStatuses[app.id]?.unread ?? 0
        return unread > 0 ? "Açık · \(unread) okunmamış" : "Açık · okunmamış yok"
    }

    private func binding(_ field: WritableKeyPath<WatchedAppConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: field] },
            set: { value in store.update(app) { $0[keyPath: field] = value } }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: config.glowColorHex) },
            set: { color in
                let hex = color.hexString
                store.update(app) { $0.glowColorHex = hex }
            }
        )
    }

    /// nil (the default sound) is the picker's "Varsayılan" entry.
    private var soundBinding: Binding<String> {
        Binding(
            get: { config.soundID ?? SoundPicker.defaultTag },
            set: { id in store.update(app) { $0.soundID = id == SoundPicker.defaultTag ? nil : id } }
        )
    }

    /// Shows the default volume until the slider is moved, which gives the app its own.
    private var volumeBinding: Binding<Double> {
        Binding(
            get: { config.volume ?? defaultVolume },
            set: { value in store.update(app) { $0.volume = value } }
        )
    }

    private func preview() {
        AlarmSoundPlayer.notification.playOnce(config.soundID ?? defaultSound, volume: config.volume ?? defaultVolume)
    }
}
