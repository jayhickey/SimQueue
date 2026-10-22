// SPDX-License-Identifier: MIT
// Exercise the release verifier with an ephemeral key, never the release secret.
import CryptoKit
import Foundation

let verifier = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let archive = directory.appendingPathComponent("fixture.zip")
let original = Data("public signature verification fixture".utf8)
try original.write(to: archive)
let key = Curve25519.Signing.PrivateKey()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
let signature = try key.signature(for: original).base64EncodedString()

func check(publicKey: String, expected: Int32) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = ["-j", "2", verifier, publicKey, archive.path, signature]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == expected else {
        throw NSError(
            domain: "SignatureTest", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Unexpected verifier exit status: \(process.terminationStatus), expected \(expected)"
            ])
    }
}

try check(publicKey: publicKey, expected: 0)
let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
try check(publicKey: otherKey, expected: 1)
try Data("tampered update".utf8).write(to: archive)
try check(publicKey: publicKey, expected: 1)
print("Sparkle verifier accepts valid signatures and rejects wrong keys and tampered archives")
