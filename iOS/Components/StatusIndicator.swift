import SwiftUI

/// Compact session state. Colour is never the only signal — symbol and text
/// carry the same information.
struct StatusIndicator: View {
    let status: SessionStatus
    var showsTitle = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbolName)
                .font(.caption)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            if showsTitle {
                Text(status.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
        .animation(.easeInOut(duration: 0.2), value: status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session status")
        .accessibilityValue(status.detail.map { "\(status.title). \($0)" } ?? status.title)
    }

    private var tint: Color {
        switch status {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .running: return .accentColor
        case .paused: return .orange
        case .error: return .red
        }
    }
}
