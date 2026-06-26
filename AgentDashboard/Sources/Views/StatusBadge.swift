import SwiftUI

struct StatusBadge: View {
    let status: AgentStatus
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(status.color.opacity(0.3))
                .frame(width: 14, height: 14)
                .scaleEffect(status.isActive && isPulsing ? 1.3 : 1.0)
                .opacity(status.isActive && isPulsing ? 0.0 : 1.0)
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            if status.isActive {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
        }
        .onChange(of: status.isActive) { active in
            if active {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            } else {
                withAnimation(.default) {
                    isPulsing = false
                }
            }
        }
    }
}
