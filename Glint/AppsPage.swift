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
                    Text("Bildirimlerini Glint'te görmek istediğin uygulamaları ekle.")
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
        }
    }
}

private struct AppRow: View {
    let app: WatchedApp
    let controller: AlarmController
    let action: () -> Void

    var body: some View {
        let config = WatchedAppStore.shared.config(for: app)
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

/// One app's own settings: notification and alarm, glow color, card position, sound and volume.
struct AppDetailPage: View {
    let app: WatchedApp
    let controller: AlarmController
    let onRemove: () -> Void

    @AppStorage(Pref.notifySound) private var defaultSound = "builtin.ding"
    @AppStorage(Pref.notifyVolume) private var defaultVolume = 0.6
    @AppStorage(Pref.notifyBannerPosition) private var defaultPositionName = BannerPosition.topRight.rawValue
    @AppStorage(Pref.notifyStyle) private var styleName = NotifyStyle.full.rawValue
    @State private var confirmingRemoval = false

    private var store: WatchedAppStore { .shared }
    private var config: WatchedAppConfig { store.config(for: app) }
    private var defaultPosition: BannerPosition { BannerPosition(rawValue: defaultPositionName) ?? .topRight }
    private var showsCards: Bool { (NotifyStyle(rawValue: styleName) ?? .full).showsBanner }

    var body: some View {
        Form {
            // Like the top of an app's page in macOS's notification settings.
            Section {
                HStack(spacing: 10) {
                    AppIcon(app: app, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Glint bildirimleri")
                        Text(app.isInstalled ? app.name : "\(app.name) · Yüklü değil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Glint bildirimleri", isOn: binding(\.enabled))
                        .labelsHidden()
                }
            }

            Section("Bildirim") {
                Toggle("Uzaktayken alarm çal", isOn: binding(\.alarmEnabled))
                Toggle("Alarmı yalnızca önemli bildirimlerde çal", isOn: binding(\.alarmOnlyImportant))
                    .disabled(!config.alarmEnabled)
                    .help("Önemli kelimeler Odak ve Öncelik sayfasından seçilir.")
                LabeledContent {
                    Button("Bildirim Ayarlarını Aç…") { app.openNotificationSettings() }
                } label: {
                    Text("macOS bildirimleri")
                    Text("Mesajlar iki kez görünmesin diye yalnızca Masaüstü'nü kapat.")
                }
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
                if showsCards {
                    LabeledContent("Kartın konumu") {
                        HStack(spacing: 12) {
                            if config.bannerPosition != nil {
                                Button("Varsayılana Dön") {
                                    store.update(app) { $0.bannerPosition = nil }
                                    controller.testNotification(for: app)
                                }
                                .buttonStyle(.borderless)
                            }
                            BannerPositionPicker(selection: positionBinding) { controller.testNotification(for: app) }
                                .frame(width: 150)
                        }
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
                    Button("Listeden Kaldır…", role: .destructive) { confirmingRemoval = true }
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

    private func binding(_ field: WritableKeyPath<WatchedAppConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: field] },
            set: { value in store.update(app) { $0[keyPath: field] = value } }
        )
    }

    /// The app's own position, or the default until one is picked. Picking the default again goes
    /// back to following it.
    private var positionBinding: Binding<BannerPosition> {
        Binding(
            get: { config.bannerPosition(default: defaultPosition) },
            set: { position in
                let own = position == defaultPosition ? nil : position
                store.update(app) { $0.bannerPosition = own }
            }
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
