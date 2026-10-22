// SPDX-License-Identifier: MIT
// Read-only Sparkle information probe; never offers or installs an update.
import AppKit
import Foundation
import Sparkle

@MainActor
final class FeedProbe: NSObject, SPUUpdaterDelegate {
    let overrideURL: String?
    var versions: [String]?
    var failure: Error?
    init(overrideURL: String?) { self.overrideURL = overrideURL }
    func feedURLString(for updater: SPUUpdater) -> String? { overrideURL }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck.rawValue == 2 else {
            throw NSError(domain: "FeedProbe", code: 1)
        }
    }
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        versions = appcast.items.map { $0.versionString }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { failure = error }
}

@main
struct Main {
    @MainActor static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data(("Feed probe failed: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    @MainActor static func run() throws {
        guard CommandLine.arguments.count >= 2,
            let bundle = Bundle(path: CommandLine.arguments[1])
        else { throw NSError(domain: "FeedProbe", code: 2) }
        _ = NSApplication.shared
        let probe = FeedProbe(overrideURL: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: probe)
        try updater.start()
        updater.checkForUpdateInformation()
        let deadline = Date().addingTimeInterval(30)
        while probe.versions == nil && probe.failure == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let versions = probe.versions, !versions.isEmpty {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "versions": versions,
                    "feed": probe.overrideURL ?? bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "",
                ], options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            if let failure = probe.failure { print("Sparkle feed error: \(failure)") }
            throw NSError(
                domain: "FeedProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "No versions loaded from feed"])
        }
    }
}
