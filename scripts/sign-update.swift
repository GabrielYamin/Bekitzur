#!/usr/bin/env swift
// Signs a release for Bekitzur's updater and prints the signature. The message is UpdateManifest.signedMessage; the two
// must stay the same. Fails unless the key matches BekitzurUpdatePublicKey in App/Info.plist, since installed copies would
// refuse a release signed with any other.
//
//   UPDATE_SIGNING_KEY=<private key> swift scripts/sign-update.swift <version> <build> <sha256 of the zip>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else { fatalError("usage: swift scripts/sign-update.swift <version> <build> <sha256>") }
let (version, build, sha256) = (CommandLine.arguments[1], CommandLine.arguments[2], CommandLine.arguments[3])
guard let encoded = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      let raw = Data(base64Encoded: encoded), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("UPDATE_SIGNING_KEY is missing or isn't a signing key")
}
let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App/Info.plist")
guard let info = NSDictionary(contentsOf: plist), let published = info["BekitzurUpdatePublicKey"] as? String,
      published == key.publicKey.rawRepresentation.base64EncodedString() else {
    fail("UPDATE_SIGNING_KEY doesn't match BekitzurUpdatePublicKey in App/Info.plist, so installed copies would refuse this release")
}
let message = Data("Bekitzur update\nversion \(version)\nbuild \(build)\nsha256 \(sha256)".utf8)
print(try key.signature(for: message).base64EncodedString())
