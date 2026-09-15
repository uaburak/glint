import AppKit
import ApplicationServices

/// Opens the System Settings panes of Glint's permissions.
enum SystemSettings {
    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS shows its prompt, which leads to the Accessibility pane.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// Something that keeps Glint from working fully. It's shown in the menu and on the Hakkında page until
/// it's fixed or, where it may be on purpose, dismissed.
enum HealthIssue: Hashable, Identifiable {
    /// Full Disk Access worked before and is gone.
    case fullDiskAccessLost
    /// Accessibility worked before and is gone.
    case accessibilityLost
    /// The notification database can't be read even with Full Disk Access (macOS may have changed it).
    case databaseUnreadable
    /// An app's badge rose with no notification record while it has none at all: its “Bildirim
    /// Merkezi” option looks off.
    case notificationCenterOff(appID: String)

    var id: Self { self }

    @MainActor var title: String {
        switch self {
        case .fullDiskAccessLost: "Tam Disk Erişimi kaldırılmış"
        case .accessibilityLost: "Erişilebilirlik izni kaldırılmış"
        case .databaseUnreadable: "Bildirim veritabanı okunamıyor"
        case .notificationCenterOff(let appID): "\(WatchedApp.find(byID: appID)?.name ?? appID): Bildirim Merkezi kapalı görünüyor"
        }
    }

    var detail: String {
        switch self {
        case .fullDiskAccessLost:
            "Mesajların içeriği gösterilemiyor ve Odak durumu okunamıyor; yeni bildirimler Dock simgelerindeki sayıdan anlaşılıyor."
        case .accessibilityLost:
            "Yalnızca Dock'ta görünen rozetler okunamıyor; bazı uygulamaların bildirimleri kaçabilir."
        case .databaseUnreadable:
            "Bir macOS güncellemesi veritabanını değiştirmiş olabilir. Bu arada yeni bildirimler Dock simgelerindeki sayıdan anlaşılıyor."
        case .notificationCenterOff:
            "Simgedeki sayı arttı ama bildirim kaydı gelmedi, bu yüzden mesajın içeriği gösterilemedi. Uygulamanın macOS bildirim ayarlarında “Bildirim Merkezi”ni aç."
        }
    }

    /// The button that fixes it, if there's one.
    var actionTitle: String? {
        switch self {
        case .fullDiskAccessLost: "Ayarları Aç…"
        case .accessibilityLost: "İzin Ver…"
        case .databaseUnreadable: nil
        case .notificationCenterOff: "Bildirim Ayarlarını Aç…"
        }
    }

    /// A permission may have been taken back on purpose; the database is Glint's to sort out.
    var isDismissible: Bool {
        self != .databaseUnreadable
    }

    @MainActor func performAction() {
        switch self {
        case .fullDiskAccessLost: SystemSettings.openFullDiskAccess()
        case .accessibilityLost: SystemSettings.requestAccessibility()
        case .databaseUnreadable: break
        case .notificationCenterOff(let appID): WatchedApp.find(byID: appID)?.openNotificationSettings()
        }
    }
}
