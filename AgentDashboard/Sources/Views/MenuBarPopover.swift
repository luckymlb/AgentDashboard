import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var scanner: ProcessScanner

    private var activeAgents: [AgentInfo] {
        scanner.agents.filter { $0.status.isActive }
    }

    private var idleAgents: [AgentInfo] {
        scanner.agents.filter { !$0.status.isActive }
    }

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
                        if !activeAgents.isEmpty {
                            SectionHeader(title: "Active", count: activeAgents.count)
                            ForEach(activeAgents) { agent in
                                AgentRowView(agent: agent)
                            }
                        }

                        if !idleAgents.isEmpty {
                            SectionHeader(title: "Idle", count: idleAgents.count)
                            ForEach(idleAgents) { agent in
                                AgentRowView(agent: agent)
                            }
                        }
                    }
                }
                .frame(maxHeight: 400)

                Divider()

                // Footer
                HStack {
                    Text("\(scanner.agents.count) agents")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("\(activeAgents.count) active")
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
