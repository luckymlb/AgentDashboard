import SwiftUI

struct AgentRowView: View {
    let agent: AgentInfo
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            ITerm2Bridge.activateSession(tty: agent.tty)
        }) {
            HStack(spacing: 8) {
                StatusBadge(status: agent.status)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(agent.projectName)
                            .font(.system(.body, design: .default))
                            .fontWeight(.medium)
                            .lineLimit(1)

                        if agent.status.isActive {
                            Text(agent.status.label)
                                .font(.caption2)
                                .foregroundColor(statusLabelColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(statusLabelColor.opacity(0.12))
                                .cornerRadius(3)
                        }
                    }
                    Text(agent.workingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(agent.elapsedTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(agent.tty)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var statusLabelColor: Color {
        switch agent.status {
        case .thinking:   return .purple
        case .crafting:   return .blue
        case .running:    return .green
        case .reading:    return .cyan
        case .editing, .writing: return .orange
        case .searching:  return .yellow
        case .processing: return .mint
        case .busy:       return .green
        case .waiting:    return .gray
        case .idle:       return .gray
        }
    }
}
