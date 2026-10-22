// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import Sparkle

    /// Sparkle owns download/signature validation and replacement. The application
    /// termination delegate owns the queue handoff, including install-on-quit.
    @MainActor
    final class AppUpdater: NSObject, SPUUpdaterDelegate {
        private(set) var controller: SPUStandardUpdaterController!
        private(set) var installationPending = false
        var mayCheck: () -> Bool = { true }
        var onAbort: () -> Void = {}
        var deferInstallation: ((@escaping () -> Void) -> Bool)?

        override init() {
            super.init()
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }

        func check() { controller.checkForUpdates(nil) }

        func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
            guard mayCheck() else {
                throw NSError(
                    domain: "SimQueue.Update", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Wait for the current daemon operation to finish before checking for updates."
                    ])
            }
        }

        func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
            installationPending = true
        }

        func updater(
            _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
            untilInvokingBlock installHandler: @escaping () -> Void
        ) -> Bool {
            installationPending = true
            // Postpone before the installer requests termination, so a long job
            // does not put Sparkle into its unresponsive-app/force-quit flow.
            return deferInstallation?(installHandler) ?? false
        }

        func updater(
            _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
        ) -> Bool {
            installationPending = true
            return false
        }

        func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
            installationPending = false
            onAbort()
        }
    }
#endif
