// SPDX-License-Identifier: MIT
// Public verification only: this code does not read any private key.
import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4,
    let key = Data(base64Encoded: CommandLine.arguments[1]),
    let signature = Data(base64Encoded: CommandLine.arguments[3])
else { fail("usage: verify-sparkle-update.swift <public key> <archive> <signature>") }
do {
    let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    guard verifier.isValidSignature(signature, for: archive) else {
        fail("Update signature does not match the public key embedded in the app")
    }
    print("Sparkle archive signature verified")
} catch { fail("Unable to verify update archive: \(error)") }
