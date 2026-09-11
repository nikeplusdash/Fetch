import SwiftUI
import FetchKit
import FetchPluginAPI

/**
 One row of the Cloud list: a glyph, a name, a size, and the badges of
 every service holding it.

 **The same `ColumnSet` as Downloads, without the rate column.** A cloud
 item is not transferring, so a Rate column would be a column of dashes;
 the points go to the badges instead. Using the shared set rather than a
 fourth hand-built grid is what keeps this screen's columns from drifting
 out of line with the two above it — which is the drift `TableColumns`
 exists to make impossible.

 **The size can be zero, and that is honest.** Premiumize's transfer
 listing reports no size until a row's files have been fetched, so an
 unhydrated row shows a dash rather than a confident "0 bytes".
 */
struct CloudRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.rowState) private var rowState
    let row: CloudRow
    let width: CGFloat
    let columns: ColumnSet<DownloadColumn>
    var isExpanded: Bool = false
    var onToggle: (() -> Void)?

    private static let noValue = "—"

    var body: some View {
        ColumnRow(set: columns, width: width) { spec in
            switch spec.id {
            case .status:
                Image(systemName: "icloud")
                    .font(.system(size: IconSize.sm))
                    .foregroundStyle(rowState.ink(Palette.textTertiary))
                    .help("On \(providerList)")
                    .accessibilityLabel("On \(providerList)")
            case .name:
                if let onToggle {
                    HStack(spacing: Spacing.s4) {
                        DisclosureChevron(
                            isExpanded: isExpanded, isExpandable: true, onToggle: onToggle)
                        RevealingText(text: row.name, isRevealing: rowState.isSelected)
                    }
                } else {
                    RevealingText(text: row.name, isRevealing: rowState.isSelected)
                }
            case .size:
                Text(row.size > 0 ? ByteCount.format(row.size) : Self.noValue)
            case .rate:
                Text(Self.noValue)
            case .added:
                HStack(spacing: Spacing.s4) {
                    ForEach(row.providers, id: \.rawValue) { provider in
                        TagPill(title: name(of: provider), tone: .quiet)
                    }
                }
            }
        }
        .font(FetchFont.calloutMono)
        .foregroundStyle(rowState.ink(Palette.textTertiary))
        .padding(.vertical, RowHeight.rowPaddingV)
        .help(row.name)
    }

    private func name(of provider: DebridProviderID) -> String {
        model.provider(provider)?.displayName ?? provider.rawValue
    }

    private var providerList: String {
        row.providers.map(name(of:)).joined(separator: ", ")
    }
}
