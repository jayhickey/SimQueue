// SPDX-License-Identifier: MIT

#if os(macOS)
    import Foundation
    import SimQueueProtocol

    enum LoginDaemon {
        /// Match the reported PID, not merely a familiar service name. Seal the daemon's
        /// admission gate before bootout so KeepAlive cannot restart it between requests.
        static func stopAction(_ status: StatusResult) throws -> (@Sendable () throws -> Void)? {
            for label in ["homebrew.mxcl.simqueue", "dev.simqueue.simqd"] {
                let target = "gui/\(getuid())/\(label)"
                let result = try launchctl(["print", target])
                guard result.0 == 0 else { continue }
                let pidLine = "pid = \(status.daemon.pid)"
                guard
                    result.1.split(separator: "\n").contains(where: {
                        $0.trimmingCharacters(in: .whitespaces) == pidLine
                    })
                else { continue }
                return {
                    let current = try launchctl(["print", target])
                    guard current.0 == 0,
                        current.1.split(separator: "\n").contains(where: {
                            $0.trimmingCharacters(in: .whitespaces) == pidLine
                        })
                    else { throw QueueStopError.serviceChanged }
                    guard try launchctl(["bootout", target]).0 == 0 else { throw QueueStopError.bootoutFailed }
                }
            }
            return nil
        }

        private enum QueueStopError: Error { case serviceChanged, bootoutFailed }

        private static func launchctl(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
#endif
