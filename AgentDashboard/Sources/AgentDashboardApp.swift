import SwiftUI
import AppKit
import Combine
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "App")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let scanner = ProcessScanner()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("applicationDidFinishLaunching")

        scanner.startScanning()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Agent Dashboard")
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            // withSymbolConfiguration can return nil for some symbol/config combos;
            // fall back to the base image so the menu bar item is never blank.
            button.image = image?.withSymbolConfiguration(config) ?? image
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        } else {
            logger.error("statusItem.button is nil")
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 200)
        popover.behavior = .transient
        let hostingController = NSHostingController(
            rootView: MenuBarPopover(scanner: scanner)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        // Drive menu bar icon + badge directly from @Published agents.
        // 有 agent 等权限确认时,图标切红色感叹号醒目提示。
        cancellable = scanner.$agents
            .sink { [weak self] agents in
                guard let self, let button = self.statusItem.button else { return }
                let active = agents.filter { $0.status.isActive }.count
                let hasConfirming = agents.contains { $0.status == .confirming }
                button.title = active > 0 ? " \(active)" : ""
                self.updateStatusBarIcon(button: button, hasConfirming: hasConfirming)
            }

        logger.info("Setup complete")
    }

    /// 菜单栏图标:有 agent 等权限确认时整体变橙色温暖提示,否则正常爪印。
    /// 保持爪印标识不变,用颜色(而非"错误感"的红色感叹号)表达"需要关注"。
    private func updateStatusBarIcon(button: NSStatusBarButton, hasConfirming: Bool) {
        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Agent Dashboard")
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if hasConfirming {
            let orangeConfig = NSImage.SymbolConfiguration(hierarchicalColor: .systemOrange)
            button.image = image?.withSymbolConfiguration(baseConfig)?.withSymbolConfiguration(orangeConfig)
            button.image?.isTemplate = false
        } else {
            button.image = image?.withSymbolConfiguration(baseConfig) ?? image
            button.image?.isTemplate = true
        }
        button.imagePosition = .imageLeading
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanner.stopScanning()
        cancellable?.cancel()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            scanner.setPollingMode(.background)
        } else {
            scanner.setPollingMode(.active)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
