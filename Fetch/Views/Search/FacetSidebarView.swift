import SwiftUI
import FetchKit

/**
 The facet sidebar (§12.1) — computed live from loaded results, so every
 click narrows instantly and never refetches.

 Counts are what make this trustworthy: each option shows how many results
 remain if it is chosen, computed against every *other* active facet but not
 its own (`Faceting.options`). A facet therefore never offers an option that
 would return nothing, and never becomes a one-way door.
 */
struct FacetSidebarView: View {
    @Environment(AppModel.self) private var model

    private static let order: [FacetDimension] = [
        .resolution, .source, .videoCodec, .hdr, .audioCodec,
        .sizeBucket, .language, .releaseGroup, .mediaKind,
    ]

    private static let maxOptionsPerDimension = 8

    @State private var expandedDimensions: Set<FacetDimension> = []

    @ViewBuilder
    private func qualityFilteredToggle(model: Bindable<AppModel>) -> some View {
        if !model.wrappedValue.filteredOutResults.isEmpty {
            Toggle(isOn: model.showsFilteredResults) {
                Text("Show \(model.wrappedValue.filteredOutResults.count) below your quality profile")
                    .font(FetchFont.footnote)
            }
            .toggleStyle(.checkbox)
        }
    }

    var body: some View {
        @Bindable var model = model
        let options = model.facetOptions

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s12) {
                cachedOnlyAndSort(model: $model)
                qualityFilteredToggle(model: $model)
                Divider()

                if !model.facetSelection.isEmpty {
                    activeFilters
                    Divider()
                }

                seederThreshold(model: $model)

                ForEach(Self.order, id: \.self) { dimension in
                    let available = options[dimension] ?? []
                    if !available.isEmpty {
                        section(dimension: dimension, options: available)
                    }
                }
            }
            .padding(Spacing.s12)
        }
    }

    private func cachedOnlyAndSort(model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Toggle("Cached only", isOn: model.cachedOnly)
                .toggleStyle(.switch)
                .font(FetchFont.callout)
                .disabled(model.wrappedValue.cacheReadiness != .ready)
                .help(model.wrappedValue.cacheReadiness == .ready
                      ? "Show only what a debrid already holds"
                      : "Cache status is unavailable, so this cannot narrow anything")

            Picker("Sort", selection: Binding(
                get: { model.wrappedValue.searchSort },
                set: { model.wrappedValue.applySort($0) }
            )) {
                ForEach(ResultSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .font(FetchFont.callout)
        }
    }


    private var activeFilters: some View {
        VStack(alignment: .leading, spacing: Spacing.s6) {
            HStack {
                Text("Filters")
                    .font(FetchFont.headline)
                Spacer()
                Button("Clear All") { model.facetSelection.clear() }
                    .buttonStyle(.borderless)
                    .font(FetchFont.footnote)
            }

            FlowLayout(spacing: Spacing.s4) {
                ForEach(Array(model.facetSelection.values), id: \.self) { value in
                    Button {
                        model.facetSelection.toggle(value)
                    } label: {
                        Pill(style: .filled, size: .mini) {
                            HStack(spacing: Spacing.s2) {
                                Text(value.value)
                                Image(systemName: "xmark")
                                    .font(.system(size: IconSize.xs, weight: .bold))
                            }
                            .font(FetchFont.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove filter \(value.value)")
                }
            }
        }
    }

    private func seederThreshold(model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            Text("Minimum seeders")
                .font(FetchFont.headline)
            HStack(spacing: Spacing.s8) {
                Slider(
                    value: Binding(
                        get: { Double(model.wrappedValue.facetSelection.minSeeders) },
                        set: { model.wrappedValue.facetSelection.minSeeders = Int($0) }),
                    in: 0...100)
                Text("\(model.wrappedValue.facetSelection.minSeeders)")
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }


    private func section(dimension: FacetDimension, options: [FacetOption]) -> some View {
        let isExpanded = expandedDimensions.contains(dimension)
        let shown = isExpanded ? options : Array(options.prefix(Self.maxOptionsPerDimension))

        return VStack(alignment: .leading, spacing: Spacing.s2) {
            Text(dimension.title)
                .font(FetchFont.headline)

            ForEach(shown) { option in
                FacetRowView(
                    label: option.label,
                    count: option.count,
                    isChecked: model.facetSelection.contains(option.value)
                ) {
                    model.facetSelection.toggle(option.value)
                }
            }

            if options.count > Self.maxOptionsPerDimension {
                Button(isExpanded
                       ? "Show fewer"
                       : "+\(options.count - Self.maxOptionsPerDimension) more") {
                    if isExpanded {
                        expandedDimensions.remove(dimension)
                    } else {
                        expandedDimensions.insert(dimension)
                    }
                }
                .buttonStyle(.plain)
                .font(FetchFont.caption2)
                .foregroundStyle(Palette.accent)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
