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
            button.title = "AG"
            let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Agent Dashboard")
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = image?.withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        } else {
            logger.error("statusItem.button is nil")
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 450)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopover(scanner: scanner)
        )

        // Drive menu bar badge directly from @Published agents
        cancellable = scanner.$agents
            .map { $0.filter { $0.status.isActive }.count }
            .removeDuplicates()
            .sink { [weak self] activeCount in
                guard let button = self?.statusItem.button else { return }
                button.title = activeCount > 0 ? " \(activeCount)" : ""
            }

        logger.info("Setup complete")
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
