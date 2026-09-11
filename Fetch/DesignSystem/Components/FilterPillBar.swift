import SwiftUI

/**
 One capsule in a `FilterPillBar`.

 **The same pill in three places.** The Downloads filters, the Library's
 category row and the Settings panes are the same control doing the same job,
 and before this each screen drew its own: Downloads had a 6pt rounded rect
 with an accent fill, Settings had a segmented picker, and the two agreed
 about nothing. Three parallel branches would have produced a fourth.

 Empty until chosen, for the reason `CategoryPillView` already gives: every
 pill carrying a fill reads as every pill being lit, and the selected one then
 has to out-shout the rest. An outline for the unchosen leaves the fill to
 mean one thing.
 */
struct FilterPill: View {
    let title: String
    var count: Int?
    let isSelected: Bool
    var height: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Pill(
                style: isSelected ? .selected : .outline,
                size: height.map { PillSize.bar(height: $0) } ?? .medium
            ) {
                HStack(spacing: Spacing.s4) {
                    Text(title)
                        .font(FetchFont.callout)
                    if let count {
                        Text("\(count)")
                            .font(FetchFont.footnoteMono)
                            .foregroundStyle(isSelected
                                             ? Palette.onSelection.opacity(PillMetrics.countInk)
                                             : Palette.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/**
 A scrolling row of `FilterPill`s.

 Scrolls horizontally without indicators, because the Settings panes and a
 wide Library both overflow a narrow window and neither should wrap: a pill
 row that becomes two rows changes the height of the bar it is in, and the bar
 is what everything below it is measured from.
 */
struct FilterPillBar<Item: Hashable, Trailing: View>: View {
    let items: [Item]
    let title: (Item) -> String
    let count: (Item) -> Int?
    let isSelected: (Item) -> Bool
    let select: (Item) -> Void
    let height: CGFloat
    var pillHeight: CGFloat?
    var fadesOverflow: Bool = false

    @State private var hidden: CGPoint = .zero

    private var fadesLeading: Bool { fadesOverflow && hidden.x > 1 }
    private var fadesTrailing: Bool { fadesOverflow && hidden.y > 1 }
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
                .padding(.horizontal, WindowMetrics.contentInset)
            }
            .scrollIndicators(.never)
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
            .animation(.easeOut(duration: 0.15), value: fadesLeading)
            .animation(.easeOut(duration: 0.15), value: fadesTrailing)

            trailing()
                .padding(.trailing, WindowMetrics.contentInset)
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

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

private enum PillBarMetrics {
    static let fadeWidth: CGFloat = 16
}


extension FilterPillBar where Trailing == EmptyView {
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
