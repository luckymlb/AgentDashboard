import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var scanner: ProcessScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Agent Dashboard")
                    .font(.headline)
                Spacer()
                Button(action: { scanner.scan() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if scanner.agents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sleep")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No agents running")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let claudeAgents = scanner.agents.filter { $0.type == .claude }
                        let codexAgents = scanner.agents.filter { $0.type == .codex }

                        if !claudeAgents.isEmpty {
                            SectionHeader(title: "Claude", count: claudeAgents.count)
                            ForEach(claudeAgents) { agent in
                                AgentRowView(agent: agent)
                            }
                        }

                        if !codexAgents.isEmpty {
                            SectionHeader(title: "Codex", count: codexAgents.count)
                            ForEach(codexAgents) { agent in
                                AgentRowView(agent: agent)
                            }
                        }
                    }
                }
                .frame(maxHeight: 400)

                Divider()

                // Footer
                HStack {
                    let total = scanner.agents.count
                    let active = scanner.agents.filter { $0.status.isActive }.count
                    Text("\(total) agents")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("\(active) active")
                        .font(.caption)
                        .foregroundColor(.green)
                    Spacer()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 360)
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text("\(title) (\(count))")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
