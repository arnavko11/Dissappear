import SwiftUI

struct StatusDot: View {
    enum State {
        case good, warning, bad, inactive

        var color: Color {
            switch self {
            case .good: return .green
            case .warning: return .orange
            case .bad: return .red
            case .inactive: return .secondary
            }
        }
    }

    let state: State

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(.black.opacity(0.08)))
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    var state: StatusDot.State?
    var systemImage: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let state { StatusDot(state: state) }
                Text(value)
                    .foregroundStyle(.primary)
            }
        } label: {
            if let systemImage {
                Label(label, systemImage: systemImage)
            } else {
                Text(label)
            }
        }
    }
}

struct TechnicalDetails: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Technical Details", isExpanded: $isExpanded) {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct ErrorCard: View {
    let error: CompanionError

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.title, systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(error.details)
            Text(error.recommendedAction)
                .foregroundStyle(.secondary)
            TechnicalDetails(text: error.technicalDetails)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 14)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
