import SwiftUI

/// A screen drawn small, the way macOS's notification settings draw theirs: a wallpaper-like
/// gradient with the menu bar's items along the top and the Dock at the bottom, the notch if asked
/// for, and whatever the choice puts on it.
struct MiniScreen<Content: View>: View {
    var notch = false
    /// The menu bar and the Dock; a lock screen has neither.
    var desktop = true
    @ViewBuilder var content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let shape = RoundedRectangle(cornerRadius: size.width * 0.06, style: .continuous)
            shape
                .fill(LinearGradient(
                    colors: [Color(red: 0.47, green: 0.66, blue: 0.86), Color(red: 0.57, green: 0.45, blue: 0.68)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(alignment: .top) {
                    if desktop { MenuBarMarks(screen: size) }
                }
                .overlay(alignment: .bottom) {
                    if desktop {
                        RoundedRectangle(cornerRadius: size.height * 0.04, style: .continuous)
                            .fill(Color(red: 0.82, green: 0.74, blue: 0.93).opacity(0.85))
                            .frame(width: size.width * 0.38, height: size.height * 0.07)
                            .padding(.bottom, size.height * 0.05)
                    }
                }
                .overlay(alignment: .top) {
                    if notch {
                        UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3, style: .continuous)
                            .fill(.black)
                            .frame(width: size.width * 0.2, height: size.height * 0.08)
                    }
                }
                .overlay { content(size) }
                .clipShape(shape)
        }
    }
}

/// The menu bar's items drawn as dashes: a row on the left, a shorter one on the right.
struct MenuBarMarks: View {
    let screen: CGSize

    static let rightCount = 4

    var body: some View {
        HStack(spacing: 0) {
            marks(5)
            Spacer(minLength: 0)
            marks(Self.rightCount)
        }
        .padding(.horizontal, Self.sideInset(screen))
        .padding(.top, screen.height * 0.045)
    }

    private func marks(_ count: Int) -> some View {
        HStack(spacing: Self.gap(screen)) {
            ForEach(0..<count, id: \.self) { _ in
                Capsule()
                    .fill(.white.opacity(0.75))
                    .frame(width: Self.width(screen), height: max(screen.height * 0.022, 1.2))
            }
        }
    }

    static func sideInset(_ screen: CGSize) -> CGFloat { screen.width * 0.06 }
    static func width(_ screen: CGSize) -> CGFloat { screen.width * 0.035 }
    static func gap(_ screen: CGSize) -> CGFloat { screen.width * 0.015 }

    /// How far in from the right edge the right-hand items reach.
    static func rightExtent(_ screen: CGSize) -> CGFloat {
        sideInset(screen) + CGFloat(rightCount) * width(screen) + CGFloat(rightCount - 1) * gap(screen)
    }
}

// MARK: - Bildirim stilleri

/// A way notifications show, the way macOS's notification settings show theirs: a small screen with
/// it on, its name and a checkbox under it. The screen can be clicked too.
struct NotificationStyleOption: View {
    enum Kind { case notch, banner, glow, menuBar }
    let kind: Kind
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 8) {
            Button { isOn.toggle() } label: {
                MiniScreen(notch: kind == .notch) { size in drawing(on: size) }
                    .aspectRatio(1.56, contentMode: .fit)
                    .frame(maxWidth: 104)
            }
            .buttonStyle(.plain)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func drawing(on size: CGSize) -> some View {
        switch kind {
        case .notch:
            // The island grown out of the notch: the app's icon on the left, the count on the right.
            UnevenRoundedRectangle(
                bottomLeadingRadius: size.height * 0.08, bottomTrailingRadius: size.height * 0.08,
                style: .continuous
            )
            .fill(.black)
            .frame(width: size.width * 0.36, height: size.height * 0.15)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Self.appColor)
                    .frame(width: size.height * 0.08)
                    .padding(.leading, size.height * 0.05)
            }
            .overlay(alignment: .trailing) {
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: size.width * 0.05, height: size.height * 0.04)
                    .padding(.trailing, size.height * 0.06)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .banner:
            RoundedRectangle(cornerRadius: size.height * 0.04, style: .continuous)
                .fill(.white.opacity(0.9))
                .frame(width: size.width * 0.3, height: size.height * 0.12)
                .padding(.top, size.height * 0.13)
                .padding(.trailing, size.width * 0.05)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        case .glow:
            // The edges lit in the app's colour.
            RoundedRectangle(cornerRadius: size.width * 0.06, style: .continuous)
                .strokeBorder(Self.appColor, lineWidth: size.width * 0.04)
                .blur(radius: size.width * 0.025)
        case .menuBar:
            // Glint's bell with the number waiting, just left of the other items.
            HStack(spacing: size.width * 0.012) {
                Image(systemName: "bell.fill")
                Text("3").fontWeight(.bold)
            }
            .font(.system(size: max(size.height * 0.1, 6)))
            .foregroundStyle(.white)
            .padding(.horizontal, size.width * 0.02)
            .padding(.vertical, size.height * 0.008)
            .background(.white.opacity(0.28), in: Capsule())
            .padding(.top, size.height * 0.02)
            .padding(.trailing, MenuBarMarks.rightExtent(size) + size.width * 0.02)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// A messaging app's colour, for the icon in the notch and the glow.
    private static let appColor = Color(red: 0.15, green: 0.83, blue: 0.4)
}

// MARK: - Small pickers

/// A small picker's panel: as wide as it's given, so the pickers grow with the settings window, and
/// as tall as a list of four choices with the same room above and below it as beside it. What goes
/// on it is laid out from its size.
struct MiniPickerPanel<Content: View>: View {
    @ViewBuilder let content: (MiniPicker) -> Content

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                content(MiniPicker(size: geometry.size))
            }
        }
        .frame(height: MiniPicker.height)
    }
}

/// Where things go on a small picker of a given size: the card, and how far in from the edges.
struct MiniPicker {
    /// A choice in a list, and the gap between two.
    static let rowHeight: CGFloat = 17
    static let rowSpacing: CGFloat = 2
    /// Room around a list of choices, the same on every side.
    static let padding: CGFloat = 6
    static let height = 4 * rowHeight + 3 * rowSpacing + 2 * padding
    static let slide = Animation.spring(response: 0.35, dampingFraction: 0.8)

    let size: CGSize

    /// The card keeps a card's shape however wide the panel gets.
    var card: CGSize { CGSize(width: min(size.width * 0.24, 44), height: max(size.height * 0.12, 9)) }
    var inset: CGFloat { size.height * 0.13 }

    var cardShape: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: card.width, height: card.height)
    }
}

/// A place on the position picker: a dot, bigger under the pointer.
private struct PickerDot: View {
    let title: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let diameter: CGFloat = hovered ? 6 : 4
        Button(action: action) {
            Circle()
                .fill(Color.secondary.opacity(hovered ? 0.9 : 0.5))
                .frame(width: diameter, height: diameter)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Kartın konumu

/// Where a card pops up: a dot at each position the card can take, and the card itself on the chosen
/// one. Clicking a dot slides the card there.
struct BannerPositionPicker: View {
    @Binding var selection: BannerPosition
    /// After the user picks one, for a preview.
    var onSelect: () -> Void = {}

    private static let positions: [BannerPosition] = [.topLeft, .topCenter, .topRight, .bottomLeft, .bottomCenter, .bottomRight]

    var body: some View {
        MiniPickerPanel { picker in
            ForEach(Self.positions) { position in
                PickerDot(title: position.title) {
                    selection = position
                    onSelect()
                }
                .position(Self.center(of: position, on: picker))
            }
            picker.cardShape
                .position(Self.center(of: selection, on: picker))
                .allowsHitTesting(false)
        }
        .animation(MiniPicker.slide, value: selection)
    }

    /// The middle of the card at `position`, which is where its dot sits.
    private static func center(of position: BannerPosition, on picker: MiniPicker) -> CGPoint {
        let size = picker.size, card = picker.card, inset = picker.inset
        let x: CGFloat = switch position {
        case .topLeft, .bottomLeft: inset + card.width / 2
        case .topCenter, .bottomCenter, .notch: size.width / 2
        case .topRight, .bottomRight: size.width - inset - card.width / 2
        }
        let y = position.isTop ? inset + card.height / 2 : size.height - inset - card.height / 2
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Kartın süresi ve içeriği

/// A small picker's choices as short buttons, one under the other; the chosen one is filled in grey.
struct ChoiceListPicker<Value: Hashable>: View {
    let choices: [(value: Value, title: String)]
    @Binding var selection: Value
    /// After the user picks one, for a preview.
    var onSelect: () -> Void = {}

    var body: some View {
        MiniPickerPanel { _ in
            VStack(spacing: MiniPicker.rowSpacing) {
                ForEach(choices, id: \.value) { choice in
                    ListChoice(title: choice.title, isSelected: choice.value == selection) {
                        selection = choice.value
                        onSelect()
                    }
                }
            }
            .padding(MiniPicker.padding)
        }
        .animation(MiniPicker.slide, value: selection)
    }
}

/// One button of a `ChoiceListPicker`: filled when chosen, lit under the pointer.
private struct ListChoice: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .frame(height: MiniPicker.rowHeight)
                .background {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.14 : (hovered ? 0.06 : 0)))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// How long a card stays up.
struct BannerDurationPicker: View {
    /// Seconds; 0 = until the card is closed.
    @Binding var seconds: Double
    /// After the user picks one, for a preview.
    var onSelect: () -> Void = {}

    /// The choices, 0 last: it stays.
    private static let choices: [Double] = [3, 6, 10, 0]

    var body: some View {
        ChoiceListPicker(
            choices: Self.choices.map { (value: $0, title: $0 > 0 ? "\(Int($0)) sn" : "Kalıcı") },
            selection: Binding(get: { selected }, set: { seconds = $0 }),
            onSelect: onSelect
        )
    }

    /// The stored value, or the nearest choice for one saved some other way.
    private var selected: Double {
        Self.choices.contains(seconds) ? seconds : (Self.choices.filter { $0 > 0 }.min { abs($0 - seconds) < abs($1 - seconds) } ?? 6)
    }
}

/// How much of a message its card shows, from everything to nothing.
struct MessagePreviewPicker: View {
    @Binding var selection: MessagePreview
    /// After the user picks one, for a preview.
    var onSelect: () -> Void = {}

    var body: some View {
        ChoiceListPicker(
            choices: MessagePreview.allCases.map { (value: $0, title: $0.title) },
            selection: $selection,
            onSelect: onSelect
        )
    }
}
