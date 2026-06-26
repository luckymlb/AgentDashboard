import SwiftUI

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.3))
                .frame(width: 14, height: 14)
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    private var statusColor: Color {
        switch status {
        case .thinking:
            return .purple
        case .crafting:
            return .blue
        case .running:
            return .green
        case .reading:
            return .cyan
        case .editing, .writing:
            return .orange
        case .searching:
            return .yellow
        case .processing:
            return .mint
        case .busy:
            return .green
        case .waiting:
            return .gray
        case .idle:
            return .gray
        }
    }
}
