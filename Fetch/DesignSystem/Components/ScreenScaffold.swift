import SwiftUI

/**
 A hairline that a theme can change.

 **`Divider()` is not themeable.** It draws AppKit's own separator colour and
 ignores `Palette.separator` entirely, so a theme that wants a quieter line —
 Midnight, whose pane is nearly black and where the stock separator is a bar
 of grey across it — has no way to ask for one. Every rule in the app is this
 instead, so there is one place a theme has to reach.

 One point, not a hairline scaled to the display: `Divider`'s own thickness
 is not exposed, and a rule that changes weight between two screens on one
 desk is worse than one that is always a point.
 */
struct ThemedDivider: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}

/**
 The heading above a list's columns.

 **Chrome, not a row.** The Downloads header used to be a row inside the
 `List`, so it scrolled away with the results and was only present when
 ungrouped. It sits above the list now, on the same `contentInset` the rows
 use, which is what makes a heading and its column one line rather than
 nearly one.
 */
struct ColumnHeaderRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .sectionLabel()
            .padding(.horizontal, WindowMetrics.contentInset)
            .padding(.top, Spacing.s8)
            .padding(.bottom, Spacing.s8)
            .accessibilityHidden(true)
    }
}

/**
 The line across the bottom of a screen that never moves.

 Left says what this screen is doing; right says what it is connected to.
 Both are one line, truncating — a rail that wraps is a rail that changes the
 height of everything above it.
 */
struct RailBar: View {
    let leading: String
    let trailing: String

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Text(leading)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Spacing.s8)
            Text(trailing)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(FetchFont.subheadline)
        .lineLimit(1)
        .padding(.horizontal, WindowMetrics.contentInset)
        .frame(height: WindowMetrics.railHeight)
        .overlay(alignment: .top) { ThemedDivider() }
    }
}

/**
 A titled run of settings.

 **No card.** `ProviderCardView` boxed three providers and said they were a
 different kind of thing from every other setting; they are not. A group is a
 tracked title and a run of rows divided by hairlines, and every pane is built
 from this and nothing else.
 */
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .sectionLabel()
                .padding(.bottom, Spacing.s2)
            content()
        }
        .padding(.horizontal, WindowMetrics.contentInset)
        .padding(.top, Spacing.s12)
        .accessibilityElement(children: .contain)
    }
}

/**
 One setting: a label, one line of help beneath it, and the control trailing.

 **The help is under the label, and it is one line.** Every setting here has a
 consequence worth a sentence; a sentence that only appears on hover may as
 well not exist, and a paragraph makes the pane a document. Where the longer
 text is genuinely worth keeping — the segment benchmark — it goes behind a
 disclosure whose summary is its finding.
 */
struct SettingRow<Control: View, Accessory: View>: View {
    let label: String
    var help: String?
    var detail: (summary: String, body: String)?
    @ViewBuilder let leadingAccessory: () -> Accessory
    @ViewBuilder let control: () -> Control

    @State private var isShowingDetail = false

    init(
        label: String,
        help: String? = nil,
        detail: (summary: String, body: String)? = nil,
        @ViewBuilder leadingAccessory: @escaping () -> Accessory,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.label = label
        self.help = help
        self.detail = detail
        self.leadingAccessory = leadingAccessory
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s6) {
            HStack(alignment: .center, spacing: Spacing.s16) {
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    HStack(spacing: Spacing.s8) {
                        leadingAccessory()
                        Text(label).font(FetchFont.body)
                    }
                    if let help {
                        Text(help)
                            .font(FetchFont.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                    if let detail { disclosure(detail) }
                }
                Spacer(minLength: Spacing.s8)
                control()
            }
            if isShowingDetail, let detail {
                Text(detail.body)
                    .font(FetchFont.subheadline)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.s8)
        .overlay(alignment: .bottom) { ThemedDivider().opacity(0.6) }
        .accessibilityElement(children: .contain)
    }

    private func disclosure(_ detail: (summary: String, body: String)) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isShowingDetail.toggle() }
        } label: {
            HStack(spacing: Spacing.s4) {
                Text(detail.summary)
                Image(systemName: isShowingDetail ? "chevron.down" : "chevron.right")
                    .font(.system(size: IconSize.xs, weight: .semibold))
            }
            .font(FetchFont.subheadline)
            .foregroundStyle(Palette.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isShowingDetail ? "\(detail.summary), showing more" : detail.summary)
    }
}

/**
 A `SettingRow` that carries no leading accessory, which is nearly all of
 them: the slot is a generic `@ViewBuilder` rather than an `AnyView`, so a
 row with a status dot and a row without it cost the same view identity.
 */
extension SettingRow where Accessory == EmptyView {
    init(
        label: String,
        help: String? = nil,
        detail: (summary: String, body: String)? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.init(
            label: label,
            help: help,
            detail: detail,
            leadingAccessory: { EmptyView() },
            control: control)
    }
}

/**
 The dot before a provider's name.
 */
struct StatusDot: View {
    static let diameter: CGFloat = 7

    enum State { case up, down, waiting, off }
    let state: State

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch state {
        case .up: Palette.cached
        case .down: Palette.miss
        case .waiting, .off: Palette.unknown
        }
    }
}
