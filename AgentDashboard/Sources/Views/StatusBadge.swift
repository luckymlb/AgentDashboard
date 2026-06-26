import SwiftUI

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        ZStack {
            Circle()
                .fill(status.color.opacity(0.3))
                .frame(width: 14, height: 14)
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
        }
    }
}
