import SwiftUI

/// The pages of the settings window, in sidebar order.
enum SettingsPage: String, CaseIterable, Identifiable {
    case about, apps, notifications, alarm, quiet, appearance, detection, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .about: "Hakkında"
        case .apps: "Uygulamalar"
        case .notifications: "Bildirim Ayarları"
        case .alarm: "Alarm Ayarları"
        case .quiet: "Odak ve Öncelik"
        case .appearance: "Görünüm Ayarları"
        case .detection: "Algılama"
        case .general: "Genel Ayarlar"
        }
    }

    var symbol: String {
        switch self {
        case .about: "info.circle"
        case .apps: "square.grid.2x2.fill"
        case .notifications: "bell.badge.fill"
        case .alarm: "alarm.fill"
        case .quiet: "moon.fill"
        case .appearance: "paintpalette.fill"
        case .detection: "person.fill.viewfinder"
        case .general: "gearshape.fill"
        }
    }

    /// The colour of the icon's tile in the sidebar, as System Settings gives each page its own.
    var tint: Color {
        switch self {
        case .about: .gray
        case .apps: .blue
        case .notifications: .red
        case .alarm: .orange
        case .quiet: .indigo
        case .appearance: .pink
        case .detection: .teal
        case .general: .gray
        }
    }
}

/// Where the settings window is: a sidebar page, or one app's own page inside Uygulamalar.
enum SettingsRoute: Hashable {
    case page(SettingsPage)
    case app(id: String)

    /// The sidebar page this belongs to.
    var page: SettingsPage {
        if case .page(let page) = self { return page }
        return .apps
    }
}

/// A sidebar symbol on its own rounded tile, the way System Settings draws its pages. The tile keeps
/// its colour on a selected row, where the symbol alone would be lost against the selection.
private struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    static let size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.gradient)
            .frame(width: Self.size, height: Self.size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // Room for the tile, which stands taller than the text alone.
            .padding(.vertical, 1)
    }
}

/// System Settings–style window content: pages in a sidebar on the left, the selected page's
/// grouped form on the right, and the page title with back/forward buttons in the window toolbar.
struct SettingsView: View {
    let controller: AlarmController
    /// Remembered, so the window reopens on the last page.
    @AppStorage("settingsPage") private var storedPage: SettingsPage = .apps
    /// Set once the user navigates; until then the window shows `storedPage`.
    @State private var route: SettingsRoute?
    /// Places visited before and after the current one, for the back and forward buttons.
    @State private var backStack: [SettingsRoute] = []
    @State private var forwardStack: [SettingsRoute] = []

    private var current: SettingsRoute { route ?? .page(storedPage) }

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section {
                    aboutRow
                        .tag(SettingsPage.about)
                }
                Section {
                    row(.apps)
                }
                Section {
                    ForEach([SettingsPage.notifications, .appearance, .alarm, .quiet, .detection]) { row($0) }
                }
                Section {
                    row(.general)
                }
            }
            // Like System Settings, the sidebar is always there.
            .toolbar(removing: .sidebarToggle)
            // Last, so the split view sees it on the column itself.
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .id(current)
                .formStyle(.grouped)
                .toggleStyle(.switch)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ControlGroup {
                            Button("Geri", systemImage: "chevron.left", action: goBack)
                                .disabled(backStack.isEmpty)
                                .keyboardShortcut("[", modifiers: .command)
                            Button("İleri", systemImage: "chevron.right", action: goForward)
                                .disabled(forwardStack.isEmpty)
                                .keyboardShortcut("]", modifiers: .command)
                        }
                        .controlGroupStyle(.navigation)
                    }
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch current {
        case .page(let page):
            pageView(page)
        case .app(let id):
            if let app = WatchedApp.find(byID: id) {
                AppDetailPage(app: app, controller: controller) { removedApp(id: id) }
            } else {
                pageView(.apps)
            }
        }
    }

    private var title: String {
        if case .app(let id) = current, let app = WatchedApp.find(byID: id) {
            return app.name
        }
        return current.page.title
    }

    @ViewBuilder
    private func pageView(_ page: SettingsPage) -> some View {
        switch page {
        case .about: AboutPage(controller: controller)
        case .apps: AppsPage(controller: controller) { show(.app(id: $0.id)) }
        case .notifications: NotificationPage(controller: controller)
        case .alarm: AlarmPage(controller: controller)
        case .quiet: QuietPage(controller: controller)
        case .appearance: AppearancePage(controller: controller)
        case .detection: DetectionPage(controller: controller)
        case .general: GeneralPage(controller: controller)
        }
    }

    // MARK: - Sidebar

    /// The List wants an optional selection; clicking empty sidebar space keeps the current page.
    private var sidebarSelection: Binding<SettingsPage?> {
        Binding(
            get: { current.page },
            set: { page in
                if let page { show(.page(page)) }
            }
        )
    }

    /// Glint's own row at the top, like the Apple Account row in System Settings. It points out
    /// problems listed on the page.
    private var aboutRow: some View {
        HStack(spacing: 10) {
            GlintIcon(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("Glint")
                    .font(.headline)
                Text(controller.healthIssues.isEmpty ? "Hakkında" : "Dikkat gerekiyor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !controller.healthIssues.isEmpty {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }

    private func row(_ page: SettingsPage) -> some View {
        Label {
            Text(page.title)
        } icon: {
            SidebarIcon(symbol: page.symbol, tint: page.tint)
        }
        .tag(page)
    }

    // MARK: - Navigation

    private func show(_ destination: SettingsRoute) {
        guard destination != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        go(to: destination)
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        go(to: previous)
    }

    private func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        go(to: next)
    }

    private func go(to destination: SettingsRoute) {
        route = destination
        storedPage = destination.page
    }

    /// After an added app is removed from its own page: back to the list, and out of the history.
    private func removedApp(id: String) {
        backStack.removeAll { $0 == .app(id: id) }
        forwardStack.removeAll { $0 == .app(id: id) }
        if backStack.last == .page(.apps) {
            backStack.removeLast()
        }
        go(to: .page(.apps))
    }
}
