import ApplicationServices
import ServiceManagement
import SwiftUI

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Preset choices plus the stored value, so a value saved earlier still shows up in the pop-up.
func choices(_ presets: [Double], including current: Double) -> [Double] {
    Array(Set(presets + [current])).sorted()
}

/// Pop-up of built-in, macOS and "silent" sounds, with a play button.
struct SoundPicker: View {
    /// Tag of the "Varsayılan" entry, shown when `defaultName` is set.
    static let defaultTag = "default"

    let title: String
    @Binding var selection: String
    /// Name of the default sound; when set, the pop-up starts with a "Varsayılan" entry.
    var defaultName: String? = nil
    let preview: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Picker(title, selection: $selection) {
                    if let defaultName {
                        Text("Varsayılan (\(defaultName))").tag(Self.defaultTag)
                        Divider()
                    }
                    Section("Yerleşik") {
                        ForEach(AlarmSoundLibrary.builtIn) { Text($0.name).tag($0.id) }
                    }
                    Section("macOS") {
                        ForEach(AlarmSoundLibrary.system) { Text($0.name).tag($0.id) }
                    }
                    Divider()
                    Text("Sessiz").tag(AlarmSoundLibrary.silentID)
                }
                .labelsHidden()
                .fixedSize()

                Button(action: preview) {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(selection == AlarmSoundLibrary.silentID ? Color.secondary.opacity(0.3) : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Dinle")
                .disabled(selection == AlarmSoundLibrary.silentID)
            }
        }
    }
}

/// Volume slider with speaker icons and a percentage; `onRelease` runs when the knob is let go.
struct VolumeRow: View {
    let title: String
    @Binding var value: Double
    var onRelease: () -> Void = {}

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $value, in: 0.1...1) { editing in
                    if !editing { onRelease() }
                }
                .frame(width: 180)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                Text("%\(Int((value * 100).rounded()))")
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }
}

// MARK: - Genel Ayarlar

struct GeneralPage: View {
    let controller: AlarmController
    @AppStorage(Pref.preventSleep) private var preventSleep = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Why switching "open at login" failed, until it's tried again.
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("İzleme & Başlangıç") {
                Toggle("Uygulamaları izle", isOn: Binding(
                    get: { !controller.isPaused },
                    set: { controller.setPaused(!$0) }
                ))
                Toggle("Mac açıldığında otomatik başlat", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        let service = SMAppService.mainApp
                        // Also skips the change made below when syncing the toggle with the system.
                        guard enabled != (service.status == .enabled) else { return }
                        do {
                            if enabled {
                                try service.register()
                            } else {
                                try service.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                        }
                        if service.status == .requiresApproval {
                            // Not a failure: macOS wants the user's approval in System Settings.
                            loginItemError = nil
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        launchAtLogin = service.status == .enabled
                    }
                if let loginItemError {
                    Label("Değiştirilemedi: \(loginItemError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Toggle("Mac'in kendiliğinden uyumasını engelle", isOn: $preventSleep)
                Hint("İzleme açıkken Mac kendiliğinden uyumaz; kapağı kapatınca yine uyur.")
            }

            Section("İzinler") {
                LabeledContent("Erişilebilirlik") {
                    if controller.canReadDock {
                        Label("İzin verildi", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("İzin Ver…", action: SystemSettings.requestAccessibility)
                    }
                }
                Hint("Dock'taki rozetleri okumak için gerekir; bazı uygulamaların rozeti yalnızca orada görünür.")

                LabeledContent("Tam Disk Erişimi (SQLite Veritabanı)") {
                    if controller.hasFullDiskAccess {
                        Label("Aktif (Sistem Kökü)", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Ayarları Aç…", action: SystemSettings.openFullDiskAccess)
                    }
                }
                Hint("Bildirim metinlerini okumak ve mesajları anında yakalamak için gerekir. İzin yoksa Glint rozetlerden çalışır.")
            }

            Section("Kısayollar") {
                ForEach(ShortcutAction.allCases) { ShortcutRecorder(action: $0) }
                Hint("Hangi uygulama öndeyse çalışır. Atamak için düğmeye tıklayıp tuş birleşimine bas (⌘, ⌥ ya da ⌃ ile); Esc vazgeçer.")
            }

            UpdateSection(updater: AppUpdater.shared)
        }
        // The user may have changed it in System Settings meanwhile.
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}

/// Automatic checks, the running version with the last check, and a found update.
private struct UpdateSection: View {
    let updater: AppUpdater

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        Section("Güncelleme") {
            Toggle("Güncellemeleri otomatik denetle", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }
            ))

            if let pending = updater.pendingVersion {
                LabeledContent {
                    Button("Yükle…", action: updater.checkForUpdates)
                } label: {
                    Label("Glint \(pending) hazır", systemImage: "arrow.down.circle.fill")
                }
            }

            LabeledContent {
                Button("Şimdi Denetle", action: updater.checkForUpdates)
                    .disabled(!updater.canCheck)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sürüm \(updater.currentVersion)")
                    // Redrawn every minute so "5 dakika önce" doesn't stand still while the page is open.
                    TimelineView(.everyMinute) { context in
                        Text(lastCheckText(now: context.date))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Hint("Güncellemeler geliştirici anahtarıyla imzalanır; imzası tutmayan bir paket indirilse bile kurulmaz.")
        }
    }

    private func lastCheckText(now: Date) -> String {
        guard let lastCheck = updater.lastCheck else { return "Henüz denetlenmedi" }
        return "Son denetim: " + Self.relativeFormatter.localizedString(for: min(lastCheck, now), relativeTo: now)
    }
}

// MARK: - Algılama

struct DetectionPage: View {
    let controller: AlarmController
    @AppStorage(Pref.idleMinutes) private var idleMinutes = 2.0
    @AppStorage(Pref.lockCountsAsAway) private var lockCountsAsAway = true

    var body: some View {
        Form {
            Section {
                Picker("Uzakta sayılma süresi", selection: $idleMinutes) {
                    ForEach(choices([1, 2, 3, 5, 10, 15, 30], including: idleMinutes), id: \.self) {
                        Text("\(Int($0)) dakika hareketsizlik").tag($0)
                    }
                }
                Toggle("Ekran kilitliyse anında uzakta say", isOn: $lockCountsAsAway)
                Hint("Klavye ve fareye bu süre boyunca dokunmazsan uzakta sayılırsın. Bilgisayar başındayken alarm çalmaz, yalnızca ışıma olur.")
            }

            Section {
                LabeledContent("Şu anki durum") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(controller.userAway ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(controller.userAway ? "Uzakta" : "Bilgisayar başında")
                    }
                }
            }
        }
    }
}

// MARK: - Alarm Ayarları

struct AlarmPage: View {
    let controller: AlarmController
    @AppStorage(Pref.alarmStyle) private var style = AlarmStyle.flash.rawValue
    @AppStorage(Pref.alarmSeconds) private var seconds = 5.0
    @AppStorage(Pref.alarmRepeatMinutes) private var repeatMinutes = 0.0
    @AppStorage(Pref.alarmSound) private var sound = AlarmSoundLibrary.defaultID
    @AppStorage(Pref.alarmVolume) private var volume = 0.5
    @AppStorage(Pref.overrideSystemVolume) private var overrideSystemVolume = true

    var body: some View {
        let apps = WatchedApp.listed
        Form {
            Section("Alarm Çalacak Uygulamalar") {
                if apps.isEmpty {
                    Text("Uygulamalar sayfasından izlenecek uygulama ekleyebilirsin.")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps) { app in
                    AlarmAppRow(app: app, controller: controller)
                }
                Hint("Uzaktayken yalnızca yukarıda açık olan uygulamalar için alarm çalar.")
            }

            Section("Ekran Efekti") {
                Picker("Alarm tarzı", selection: $style) {
                    ForEach(AlarmStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)

                Hint((AlarmStyle(rawValue: style) ?? .flash).detail)

                Picker("Alarm süresi", selection: $seconds) {
                    ForEach(choices([3, 5, 10, 15, 30], including: seconds), id: \.self) {
                        Text("\(Int($0)) saniye").tag($0)
                    }
                }
            }

            Section("Tekrar") {
                Picker("Alarmı tekrarla", selection: $repeatMinutes) {
                    Text("Tekrarlama").tag(0.0)
                    Divider()
                    ForEach(choices([1, 2, 5, 10, 15, 30], including: repeatMinutes).filter { $0 > 0 }, id: \.self) {
                        Text("\(Int($0)) dakikada bir").tag($0)
                    }
                }
                Hint("Bildirim okunmadıkça alarm bu aralıkla tekrarlar; klavyeye ya da fareye dokununca durur.")
            }

            Section("Ses") {
                SoundPicker(title: "Alarm sesi", selection: $sound, preview: preview)
                VolumeRow(title: "Ses seviyesi", value: $volume, onRelease: preview)
                Toggle("Mac sessizde olsa bile alarmı duyur", isOn: $overrideSystemVolume)
                Hint(overrideSystemVolume
                     ? "Mac sessizde olsa bile alarm bu seviyede çalar; bitince ses eski haline döner."
                     : "Alarm, Mac'in mevcut ses seviyesine bağlı kalır.")
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        controller.testAlarm()
                    } label: {
                        Label("Alarmı Şimdi Test Et", systemImage: "alarm.waves.left.and.right.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
        .onChange(of: sound) { preview() }
        .onDisappear { AlarmSoundPlayer.shared.stop() }
    }

    private func preview() {
        AlarmSoundPlayer.shared.play(sound, volume: volume, overrideSystemVolume: overrideSystemVolume, duration: 2.0)
    }
}

/// A row on the alarm page to switch an app's alarm on or off.
private struct AlarmAppRow: View {
    let app: WatchedApp
    let controller: AlarmController

    var body: some View {
        let config = WatchedAppStore.shared.config(for: app)
        HStack(spacing: 12) {
            AppIcon(app: app, size: 22)

            Text(app.name)
                .font(.system(.body, weight: .medium))
            if !config.enabled {
                tag("Bildirim Kapalı", color: .orange)
            }
            if config.alarmEnabled && config.alarmOnlyImportant {
                tag("Yalnızca önemli", color: .indigo)
            }

            Spacer()

            Button {
                controller.testAlarm(for: app)
            } label: {
                Label("Test Et", systemImage: "bell.and.waves.left.and.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("\(app.name) için tam ekran alarmını test eder")

            Toggle("", isOn: Binding(
                get: { config.alarmEnabled },
                set: { value in WatchedAppStore.shared.update(app) { $0.alarmEnabled = value } }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
