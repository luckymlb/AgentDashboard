import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let scanner = ProcessScanner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("AgentDashboard: applicationDidFinishLaunching called")

        scanner.startScanning()
        NSLog("AgentDashboard: scanner started, agents count = \(scanner.agents.count)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSLog("AgentDashboard: statusItem created = \(statusItem != nil)")

        if let button = statusItem.button {
            button.title = "AG"
            let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Agent Dashboard")
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = image?.withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
            NSLog("AgentDashboard: button configured")
        } else {
            NSLog("AgentDashboard: ERROR - button is nil")
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 450)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopover(scanner: scanner)
        )

        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateStatusIcon()
        }
        updateStatusIcon()
        NSLog("AgentDashboard: setup complete")
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusIcon() {
        let activeCount = scanner.agents.filter { $0.status.isActive }.count
        if let button = statusItem.button {
            if activeCount > 0 {
                button.title = " \(activeCount)"
            } else {
                button.title = ""
            }
        }
    }
}
