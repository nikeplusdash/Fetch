import SwiftUI

/// One capsule in a `FilterPillBar`.
///
/// **The same pill in three places.** The Downloads filters, the Library's
/// category row and the Settings panes are the same control doing the same job,
/// and before this each screen drew its own: Downloads had a 6pt rounded rect
/// with an accent fill, Settings had a segmented picker, and the two agreed
/// about nothing. Three parallel branches would have produced a fourth.
///
/// Empty until chosen, for the reason `CategoryPillView` already gives: every
/// pill carrying a fill reads as every pill being lit, and the selected one then
/// has to out-shout the rest. An outline for the unchosen leaves the fill to
/// mean one thing.
struct FilterPill: View {
    let title: String
    /// Shown after the title. Nil where a count would say nothing — the
    /// Settings panes, which cannot be counted.
    var count: Int?
    let isSelected: Bool
    /// Fixed height, for a bar whose pills are the screen's primary control and
    /// have to match the search field across the divider. Nil elsewhere, where
    /// the pill sizes to its own text — the Library's second row is not a
    /// primary control and should not read as one.
    var height: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s4) {
                Text(title)
                    .font(FetchFont.callout)
                if let count {
                    Text("\(count)")
                        .font(FetchFont.footnoteMono)
                        .foregroundStyle(isSelected
                                         ? Palette.onSelection.opacity(0.7)
                                         : Palette.textTertiary)
                }
            }
            .padding(.horizontal, height == nil ? Spacing.s12 : Spacing.s16)
            // **Height instead of vertical padding, not as well as.** A padded
            // pill given a frame keeps the padding inside it, so the capsule
            // grows but the text sits in a taller box than it needs and the
            // row's rhythm comes from two rules at once.
            .padding(.vertical, height == nil ? Spacing.s4 : 0)
            .frame(height: height)
            .foregroundStyle(isSelected ? Palette.onSelection : Palette.textPrimary)
            .background(Capsule().fill(isSelected ? Palette.selection : .clear))
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? .clear : Palette.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A scrolling row of `FilterPill`s.
///
/// Scrolls horizontally without indicators, because the Settings panes and a
/// wide Library both overflow a narrow window and neither should wrap: a pill
/// row that becomes two rows changes the height of the bar it is in, and the bar
/// is what everything below it is measured from.
struct FilterPillBar<Item: Hashable, Trailing: View>: View {
    let items: [Item]
    let title: (Item) -> String
    let count: (Item) -> Int?
    let isSelected: (Item) -> Bool
    let select: (Item) -> Void
    /// The bar's own height. `barHeight` for a screen's primary row,
    /// `subBarHeight` for the Library's second one.
    let height: CGFloat
    /// The height of the pills *within* that bar. Nil lets each size to its own
    /// text; a value makes them the bar, which is what a row of pills standing
    /// in for the search field has to be.
    var pillHeight: CGFloat?
    /// Fade the trailing edge when the pills are wider than the room they have.
    /// For a row that genuinely overflows — Settings' eight panes — where a pill
    /// cut through the middle of a word reads as a layout fault rather than as
    /// "there is more this way".
    var fadesOverflow: Bool = false

    /// How much row is off each edge *at the current scroll position* — `x`
    /// behind the leading edge, `y` past the trailing one. Kept here rather
    /// than passed in, so a bar that fades is self-contained.
    @State private var hidden: CGPoint = .zero

    /// **Not "is the row wider than the window" — "is there anything past this
    /// edge right now".** A width comparison fades whenever the row overflows
    /// at all, including once it has been scrolled to the end, which puts the
    /// last pill under the gradient and washes out the one thing the user just
    /// scrolled over to reach.
    private var fadesLeading: Bool { fadesOverflow && hidden.x > 1 }
    private var fadesTrailing: Bool { fadesOverflow && hidden.y > 1 }
    /// Trailing content — Add Link, Clear. Sits after the scrolling pills, so
    /// they keep the left edge whatever it contains.
    @ViewBuilder let trailing: () -> Trailing

    init(
        items: [Item],
        title: @escaping (Item) -> String,
        count: @escaping (Item) -> Int? = { _ in nil },
        isSelected: @escaping (Item) -> Bool,
        select: @escaping (Item) -> Void,
        height: CGFloat = WindowMetrics.barHeight,
        pillHeight: CGFloat? = nil,
        fadesOverflow: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.items = items
        self.title = title
        self.count = count
        self.isSelected = isSelected
        self.select = select
        self.height = height
        self.pillHeight = pillHeight
        self.fadesOverflow = fadesOverflow
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Spacing.s10) {
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.s6) {
                    ForEach(items, id: \.self) { item in
                        FilterPill(
                            title: title(item),
                            count: count(item),
                            isSelected: isSelected(item),
                            height: pillHeight,
                            action: { select(item) })
                    }
                }
                // The pills' own inset is the bar's, so a pill's left edge and
                // the first column of the list beneath it are one line.
                .padding(.horizontal, WindowMetrics.contentInset)
            }
            .scrollIndicators(.never)
            // Reads the scroll itself rather than measured widths: the question
            // is what is past each edge *now*, and only the scroll geometry
            // knows that.
            .onScrollGeometryChange(for: CGPoint.self) { geometry in
                CGPoint(
                    x: geometry.contentOffset.x,
                    y: geometry.contentSize.width
                        - geometry.contentOffset.x
                        - geometry.containerSize.width)
            } action: { _, offsets in
                hidden = offsets
            }
            .mask(mask)
            // The fade is a statement about the scroll, so it arrives and
            // leaves with one — appearing without warning as your finger stops
            // reads as the row flinching.
            .animation(.easeOut(duration: 0.15), value: fadesLeading)
            .animation(.easeOut(duration: 0.15), value: fadesTrailing)

            trailing()
                .padding(.trailing, WindowMetrics.contentInset)
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    /// Opaque at an edge with nothing past it — a fade over a row that has
    /// nowhere left to go is just a washed-out end pill.
    private var mask: some View {
        HStack(spacing: 0) {
            if fadesLeading {
                LinearGradient(
                    colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: PillBarMetrics.fadeWidth)
            }
            Color.black
            if fadesTrailing {
                LinearGradient(
                    colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: PillBarMetrics.fadeWidth)
            }
        }
    }
}

/// Outside the type because `FilterPillBar` is generic, and a generic type
/// cannot hold a static stored property.
private enum PillBarMetrics {
    /// **A fixed band, not a percentage.** The same reasoning — and the same
    /// number — as Search's category row: a proportional fade eats more of the
    /// row the wider the window gets, washing out a pill that fits perfectly
    /// well. A hint is the same few points whatever the window is doing.
    static let fadeWidth: CGFloat = 16
}


extension FilterPillBar where Trailing == EmptyView {
    /// A bar with nothing after the pills — the Library's category row, and the
    /// Settings panes.
    init(
        items: [Item],
        title: @escaping (Item) -> String,
        count: @escaping (Item) -> Int? = { _ in nil },
        isSelected: @escaping (Item) -> Bool,
        select: @escaping (Item) -> Void,
        height: CGFloat = WindowMetrics.barHeight,
        pillHeight: CGFloat? = nil,
        fadesOverflow: Bool = false
    ) {
        self.init(
            items: items, title: title, count: count,
            isSelected: isSelected, select: select, height: height,
            pillHeight: pillHeight, fadesOverflow: fadesOverflow,
            trailing: { EmptyView() })
    }
}
