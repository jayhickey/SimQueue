// SPDX-License-Identifier: MIT

#if os(macOS)
    import Foundation
    import Darwin
    import ServiceManagement
    import SimQueueMenuBar
    import SimQueueProtocol

    enum BundledDaemon {
        static var service: SMAppService { .agent(plistName: AppDaemonSettings.plistName) }

        static func validate(paths: SimQueuePaths) throws {
            let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
            guard parent == "/Applications" || parent == NSHomeDirectory() + "/Applications" else {
                throw ServiceError.installApp
            }
            let config = try Data(contentsOf: URL(fileURLWithPath: paths.configPath))
            try AppDaemonSettings.validate(config: config, stateDirectory: paths.stateDir, home: NSHomeDirectory())
            // A stopped-but-installed legacy login agent can return at next login.
            // Never delete or silently reconfigure another manager from the app.
            let agents = NSHomeDirectory() + "/Library/LaunchAgents/"
            for label in LoginDaemon.legacyLabels {
                guard !FileManager.default.fileExists(atPath: agents + label + ".plist") else {
                    throw ServiceError.legacyManager
                }
            }
        }

        static func register(paths: SimQueuePaths, waitForExit: Bool = false) throws {
            try validate(paths: paths)
            if service.status == .enabled { return }
            // Do not treat a missing socket as proof that startup/recovery ended.
            let deadline = Date().addingTimeInterval(waitForExit ? 10 : 0)
            while !locksAvailable(paths: paths) {
                guard Date() < deadline else { throw ServiceError.otherDaemon }
                Thread.sleep(forTimeInterval: 0.1)
            }
            try service.register()
        }

        private static func locksAvailable(paths: SimQueuePaths) -> Bool {
            for path in [paths.lockPath, SimQueuePaths.hostLockPath(environment: ["HOME": NSHomeDirectory()])] {
                let fd = open(path, O_RDONLY)
                if fd < 0 {
                    if errno == ENOENT { continue }
                    return false
                }
                let available = flock(fd, LOCK_EX | LOCK_NB) == 0
                if available { _ = flock(fd, LOCK_UN) }
                close(fd)
                if !available { return false }
            }
            return true
        }

        /// Scriptable equivalent of Finish Jobs and Quit for app upgrades.
        /// Always match the daemon epoch and manager before changing admission.
        static func stop(paths: SimQueuePaths) throws {
            try validate(paths: paths)
            let session = QueueSession(socketPath: paths.socketPath)
            let status = try session.status()
            guard try owns(status) else { throw ServiceError.otherDaemon }
            _ = try session.beginStop(cancelActive: false, expectedEpoch: status.daemon.epoch)
            let deadline = Date().addingTimeInterval(30 * 60)
            while try !session.finishStop(expectedEpoch: status.daemon.epoch, service: LoginDaemon.stopAction) {
                guard Date() < deadline else { throw ServiceError.drainTimeout }
                Thread.sleep(forTimeInterval: 1)
            }
        }

        static func owns(_ status: StatusResult) throws -> Bool {
            try LoginDaemon.matches(label: AppDaemonSettings.label, pid: status.daemon.pid)
        }

        enum ServiceError: Error, LocalizedError {
            case legacyManager, otherDaemon, installApp, drainTimeout
            var errorDescription: String? {
                switch self {
                case .drainTimeout:
                    "Timed out waiting for jobs or cleanup. The queue remains drained; inspect status before retrying or resuming."
                case .installApp:
                    "Install SimQueue.app in /Applications or ~/Applications before enabling its background service."
                case .legacyManager:
                    "A Homebrew or legacy daemon service is still installed. Drain and back up the queue, then stop that service and move its LaunchAgent aside before enabling the bundled daemon. See docs/MENU_BAR.md."
                case .otherDaemon:
                    "The connected daemon belongs to another manager. Follow the migration steps in docs/MENU_BAR.md before switching; no daemon was stopped."
                }
            }
        }
    }
#endif
