import SwiftUI

/// A hairline that a theme can change.
///
/// **`Divider()` is not themeable.** It draws AppKit's own separator colour and
/// ignores `Palette.separator` entirely, so a theme that wants a quieter line —
/// Midnight, whose pane is nearly black and where the stock separator is a bar
/// of grey across it — has no way to ask for one. Every rule in the app is this
/// instead, so there is one place a theme has to reach.
///
/// One point, not a hairline scaled to the display: `Divider`'s own thickness
/// is not exposed, and a rule that changes weight between two screens on one
/// desk is worse than one that is always a point.
struct ThemedDivider: View {
    /// `.horizontal` draws a line *across*, like `Divider()` in a `VStack`.
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

/// The heading above a list's columns.
///
/// **Chrome, not a row.** The Downloads header used to be a row inside the
/// `List`, so it scrolled away with the results and was only present when
/// ungrouped. It sits above the list now, on the same `contentInset` the rows
/// use, which is what makes a heading and its column one line rather than
/// nearly one.
struct ColumnHeaderRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .sectionLabel()
            .padding(.horizontal, WindowMetrics.contentInset)
            .padding(.top, Spacing.s8)
            .padding(.bottom, Spacing.s8)
            .accessibilityHidden(true)   // the rows carry their own labels
    }
}

/// The line across the bottom of a screen that never moves.
///
/// Left says what this screen is doing; right says what it is connected to.
/// Both are one line, truncating — a rail that wraps is a rail that changes the
/// height of everything above it.
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

/// A titled run of settings.
///
/// **No card.** `ProviderCardView` boxed three providers and said they were a
/// different kind of thing from every other setting; they are not. A group is a
/// tracked title and a run of rows divided by hairlines, and every pane is built
/// from this and nothing else.
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

/// One setting: a label, one line of help beneath it, and the control trailing.
///
/// **The help is under the label, and it is one line.** Every setting here has a
/// consequence worth a sentence; a sentence that only appears on hover may as
/// well not exist, and a paragraph makes the pane a document. Where the longer
/// text is genuinely worth keeping — the segment benchmark — it goes behind a
/// disclosure whose summary is its finding.
struct SettingRow<Control: View>: View {
    let label: String
    var help: String?
    /// A longer explanation, behind a disclosure whose summary is its finding.
    ///
    /// **The escape hatch, and it is deliberately narrow.** One pane carried
    /// ninety-one words of benchmark under a stepper; the measurement is real
    /// and worth keeping, and a paragraph in the pane makes the pane a
    /// document. Someone tuning the setting opens this. Everyone else reads the
    /// summary and moves on.
    var detail: (summary: String, body: String)?
    /// Drawn before the label. The provider status dot, and nothing else so far.
    var leadingAccessory: AnyView?
    @ViewBuilder let control: () -> Control

    @State private var isShowingDetail = false

    init(
        label: String,
        help: String? = nil,
        detail: (summary: String, body: String)? = nil,
        leadingAccessory: AnyView? = nil,
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
                        if let leadingAccessory { leadingAccessory }
                        Text(label).font(FetchFont.body)
                    }
                    if let help {
                        Text(help)
                            .font(FetchFont.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            // The rows span the column now, and a sentence that
                            // runs the full width of a widened window is the
                            // thing the old 720-point measure was actually
                            // protecting. It applies here and nowhere else: a
                            // label and a control want the width, prose does
                            // not.
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
        // Eight, not twelve. A settings row carries two lines by design, so it
        // is always taller than a list row — but it was coming to 56 points
        // against the results list's 36, which made one screen read as roomy
        // and the other as dense when they are the same app.
        .padding(.vertical, Spacing.s8)
        .overlay(alignment: .bottom) { ThemedDivider().opacity(0.6) }
        .accessibilityElement(children: .contain)
    }

    /// The summary is a sentence, not the word "More": it is the finding, so
    /// the paragraph behind it is optional rather than mandatory reading.
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

/// The dot before a provider's name.
struct StatusDot: View {
    /// **Four, not three.** "Configured but not yet asked" is its own state:
    /// drawing it as a failure makes every launch look broken for as long as
    /// the network takes, and drawing it as success is the bug this replaced.
    enum State { case up, down, waiting, off }
    let state: State

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 7, height: 7)
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
