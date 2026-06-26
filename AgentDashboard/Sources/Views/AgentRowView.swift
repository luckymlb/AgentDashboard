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
                                .foregroundColor(agent.status.color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(agent.status.color.opacity(0.12))
                                .cornerRadius(3)
                        }
                    }
                    Text(shortPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(agent.elapsedTime)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            .cornerRadius(6)
            .opacity(agent.status.isActive || isHovered ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .help(agent.workingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var shortPath: String {
        let full = agent.workingDirectory
        let components = full.components(separatedBy: "/").filter { !$0.isEmpty }
        if components.count <= 2 {
            return "~/\(components.joined(separator: "/"))"
        }
        let last2 = components.suffix(2).joined(separator: "/")
        return "…/\(last2)"
    }
}
