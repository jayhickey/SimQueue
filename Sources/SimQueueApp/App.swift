// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import ServiceManagement
    import SimQueueDashboard
    import SimQueueMenuBar
    import SimQueueProtocol

    /// A single worker owns run(); the immutable server is only read to open its URL.
    private final class DashboardHost: @unchecked Sendable {
        let server: DashboardServer
        init(socketPath: String) throws { server = try DashboardServer(socketPath: socketPath) }
        func start() { Thread.detachNewThread { [self] in try? server.run() } }
    }

    @MainActor
    final class AppDelegate: NSObject, NSApplicationDelegate {
        private var item: NSStatusItem!
        private var timer: Timer?
        private var dashboard: DashboardHost?
        private let paths = SimQueuePaths.resolve()
        private var latest: StatusResult?
        private var stoppingEpoch: Int64?
        private var refreshing = false
        private var restartingBundled = false
        private var managingBundled = false
        private var statusLine = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")

        func applicationDidFinishLaunching(_ notification: Notification) {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: "SimQueue")
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            refresh()
        }

        @objc private func clicked() {
            if NSApp.currentEvent?.type == .rightMouseUp {
                showMenu()
            } else {
                openDashboard()
            }
        }

        private func showMenu() {
            let menu = NSMenu()
            statusLine.isEnabled = false
            menu.addItem(statusLine)
            menu.addItem(.separator())
            add("Open Dashboard", #selector(openDashboard), to: menu)
            add("Launch at Login", #selector(toggleLogin), to: menu)
            menu.items.last?.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.items.last?.isEnabled = stoppingEpoch == nil && !managingBundled
            menu.addItem(.separator())
            add("Use Bundled Daemon…", #selector(useBundledDaemon), to: menu)
            menu.items.last?.isEnabled = stoppingEpoch == nil && !managingBundled
            add("Background Service Settings…", #selector(backgroundSettings), to: menu)
            add("Stop SimQueue…", #selector(stopQueue), to: menu)
            menu.items.last?.isEnabled = latest != nil && stoppingEpoch == nil && !managingBundled
            add(
                stoppingEpoch == nil ? "Quit Menu Bar App" : "Quit App (Leave Queue Draining)", #selector(quitApp),
                to: menu)
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        }

        private func add(_ title: String, _ action: Selector, to menu: NSMenu) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }

        @objc private func openDashboard() {
            do {
                if dashboard == nil {
                    let host = try DashboardHost(socketPath: paths.socketPath)
                    host.start()
                    dashboard = host
                }
                if let text = dashboard?.server.url, let url = URL(string: text) {
                    NSWorkspace.shared.open(url)
                }
            } catch { showError(error) }
        }

        private func refresh() {
            guard !refreshing else { return }
            refreshing = true
            let session = QueueSession(socketPath: paths.socketPath)
            let epoch = stoppingEpoch
            Task {
                let result = await Task.detached { () -> Result<(StatusResult, Bool), Error> in
                    Result {
                        let status = try session.status()
                        let stopped =
                            try epoch.map { try session.finishStop(expectedEpoch: $0, service: LoginDaemon.stopAction) }
                            ?? false
                        return (status, stopped)
                    }
                }.value
                refreshing = false
                switch result {
                case .success(let (status, stopped)):
                    latest = status
                    if stopped {
                        if restartingBundled {
                            restartingBundled = false
                            stoppingEpoch = nil
                            latest = nil
                            startBundled(waitForExit: true)
                        } else {
                            quitApp()
                        }
                        return
                    }
                    let state =
                        epoch != nil ? "Stopping" : status.draining ? "Draining" : status.paused ? "Paused" : "SimQueue"
                    statusLine.title = "\(state) · \(status.running) running · \(status.queued) queued"
                    item.button?.title = " \(status.running)/\(status.queued)"
                    item.button?.toolTip = statusLine.title + "\nClick to open; right-click for options."
                case .failure(let error):
                    latest = nil
                    item.button?.title = " !"
                    statusLine.title = "Daemon unavailable"
                    item.button?.toolTip = "SimQueue disconnected. Right-click for options."
                    if stoppingEpoch != nil {
                        stoppingEpoch = nil
                        restartingBundled = false
                        managingBundled = false
                        showError(error)
                    }
                }
            }
        }

        private func startBundled(waitForExit: Bool = false) {
            managingBundled = true
            let paths = paths
            Task {
                let result = await Task.detached {
                    Result { try BundledDaemon.register(paths: paths, waitForExit: waitForExit) }
                }.value
                managingBundled = false
                switch result {
                case .success:
                    if BundledDaemon.service.status == .requiresApproval { backgroundSettings() }
                    refresh()
                case .failure(let error): showError(error)
                }
            }
        }

        @objc private func backgroundSettings() { SMAppService.openSystemSettingsLoginItems() }

        @objc private func useBundledDaemon() {
            guard stoppingEpoch == nil && !managingBundled else { return }
            do { try BundledDaemon.validate(paths: paths) } catch { showError(error); return }
            let alert = NSAlert()
            alert.messageText = "Use the daemon inside SimQueue.app?"
            alert.informativeText =
                "The background service keeps running when you quit the menu bar app. If it is already running, jobs will finish before it restarts with this app's version. macOS may ask you to allow background activity or external-drive access."
            alert.addButton(withTitle: "Use Bundled Daemon")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            managingBundled = true
            let session = QueueSession(socketPath: paths.socketPath)
            Task {
                let result = await Task.detached { () -> Result<StatusResult?, Error> in
                    Result {
                        // No answer is not proof the daemon has stopped. Registration
                        // still checks legacy agents; daemon locks prevent a second owner.
                        let status: StatusResult
                        do { status = try session.status() } catch { return nil }
                        guard try BundledDaemon.owns(status) else { throw BundledDaemon.ServiceError.otherDaemon }
                        return try session.beginStop(cancelActive: false, expectedEpoch: status.daemon.epoch)
                    }
                }.value
                switch result {
                case .success(let status):
                    if let status {
                        restartingBundled = true
                        stoppingEpoch = status.daemon.epoch
                        refresh()
                    } else {
                        startBundled()
                    }
                case .failure(let error): managingBundled = false; showError(error)
                }
            }
        }

        @objc private func stopQueue() {
            guard let latest else { return }
            let alert = NSAlert()
            alert.messageText = "Stop SimQueue?"
            alert.informativeText =
                "\(latest.running + latest.admitted) active jobs; \(latest.queued) queued. New starts will pause. Queued jobs stay saved for the next launch."
            alert.addButton(withTitle: "Finish Jobs and Quit")
            alert.addButton(withTitle: "Cancel Active Jobs and Quit")
            alert.addButton(withTitle: "Keep Running")
            alert.buttons[1].hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            let choice = alert.runModal()
            guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
            let session = QueueSession(socketPath: paths.socketPath)
            let epoch = latest.daemon.epoch
            stoppingEpoch = epoch
            let cancel = choice == .alertSecondButtonReturn
            Task {
                let result = await Task.detached {
                    Result { try session.beginStop(cancelActive: cancel, expectedEpoch: epoch) }
                }.value
                switch result {
                case .success: refresh()
                case .failure(let error): stoppingEpoch = nil; showError(error)
                }
            }
        }

        @objc private func toggleLogin() {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                    if SMAppService.mainApp.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            } catch { showError(error) }
        }

        private func showError(_ error: Error) {
            let alert = NSAlert()
            alert.messageText = "SimQueue could not complete the action"
            alert.informativeText =
                "\(error)\nRefresh the dashboard before retrying. If stopping was interrupted, inspect the daemon before retrying. Use simq resume before the final stop acknowledgement; after acknowledgement, restart the daemon."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }

        @objc private func quitApp() {
            NSApp.terminate(nil)
        }
    }

    @main
    enum MenuBarApp {
        static func main() throws {
            if CommandLine.arguments.contains("--register-daemon") {
                try BundledDaemon.register(paths: .resolve())
                print("Bundled daemon service: \(BundledDaemon.service.status)")
                return
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        }
    }
#else
    @main
    enum MenuBarApp {
        static func main() { print("SimQueueApp requires macOS 14 or later.") }
    }
#endif
