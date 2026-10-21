// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import SimQueueDashboard

struct Dashboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a read-only local queue dashboard (Ctrl-C to stop).")

    @OptionGroup var connection: Connection
    @Option(help: "Loopback port; 0 chooses an available port.") var port: UInt16 = 0
    @Flag(help: "Print the URL without opening a browser.") var noOpen = false

    func run() throws {
        let server = try DashboardServer(port: port, socketPath: connection.paths.socketPath)
        FileHandle.standardOutput.write(Data("SimQueue dashboard: \(server.url)\n".utf8))
        FileHandle.standardOutput.write(
            Data("Read-only • Ctrl-C to stop. Keep this URL private: it grants access to commands and logs.\n".utf8))
        #if os(macOS)
            if !noOpen {
                let opener = Process()
                opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                opener.arguments = [server.url]
                try opener.run()
            }
        #endif
        try server.run()
    }
}
