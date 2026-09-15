import AppKit
import SwiftUI

/// The short "wake up" alarm on the Mac: an overlay on every display (flashing or calm)
/// plus the chosen sound. macOS never lets an app draw over the lock screen, so while
/// the Mac is locked only the sound is audible.
@MainActor
final class AlarmOverlay {
    private var windows: [NSWindow] = []
    private var dismissWork: DispatchWorkItem?

    func show(unread: Int, appName: String = "TEAMS", settings: AppSettings) {
        dismiss()
        Display.wakeIfAsleep()

        if settings.alarmStyle != .off {
            for screen in NSScreen.screens {
                let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.level = .screenSaver
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.isReleasedWhenClosed = false
                // A single click dismisses it, even though Glint isn't the active app.
                window.contentView = FirstMouseHostingView(rootView: AlarmView(unread: unread, appName: appName, style: settings.alarmStyle) { [weak self] in
                    self?.dismiss()
                })
                window.setFrame(screen.frame, display: true)
                window.orderFrontRegardless()
                windows.append(window)
            }
        }

        AlarmSoundPlayer.shared.play(
            settings.alarmSoundID,
            volume: settings.alarmVolume,
            overrideSystemVolume: settings.overrideSystemVolume,
            duration: settings.alarmDuration
        )

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.alarmDuration, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        AlarmSoundPlayer.shared.stop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private struct AlarmView: View {
    let unread: Int
    let appName: String
    let style: AlarmStyle
    let onDismiss: () -> Void
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let intense = style == .flash

            ZStack {
                if intense {
                    (Int(t * 6) % 2 == 0 ? Color.red : Color(red: 0.3, green: 0, blue: 0))
                        .opacity(0.88)
                } else {
                    Color.black.opacity(0.45)
                }

                card
                    .offset(x: intense ? sin(t * 55) * 22 : sin(t * 9) * 10,
                            y: intense ? cos(t * 43) * 8 : 0)
                    .rotationEffect(.degrees(intense ? sin(t * 37) * 2.5 : sin(t * 9) * 1))
            }
            .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    private var card: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 120, weight: .bold))
            Text(appName.uppercased())
                .font(.system(size: 72, weight: .black))
            Text("\(unread) okunmamış bildirim")
                .font(.system(size: 36, weight: .semibold))
            Text("Kapatmak için tıkla")
                .font(.title3)
                .opacity(0.75)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 80)
        .padding(.vertical, 56)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 36))
    }
}
