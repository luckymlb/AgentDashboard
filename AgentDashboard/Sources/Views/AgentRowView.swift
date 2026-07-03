import SwiftUI

struct AgentRowView: View {
    let agent: AgentInfo
    var onRead: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            onRead?()
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

                        if agent.hasUnread {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                        }
                    }
                    Text(shortPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if !agent.elapsedTime.isEmpty {
                    Text(agent.elapsedTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if !agent.status.isActive, agent.lastActiveAt > 0 {
                    Text(relativeTime(agent.lastActiveAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                agent.status == .confirming
                    ? Color.red.opacity(0.12)
                    : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .cornerRadius(6)
            .opacity(agent.status.isActive || agent.hasUnread || isHovered ? 1.0 : 0.55)
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

    private func relativeTime(_ msTimestamp: Double) -> String {
        let seconds = Int(Date().timeIntervalSince1970 - msTimestamp / 1000)
        guard seconds > 0 else { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
