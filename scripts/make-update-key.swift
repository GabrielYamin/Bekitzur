#!/usr/bin/env swift
// Makes the key pair that signs Bekitzur's updates, and prints the public key. The private key belongs in the private
// repository's UPDATE_SIGNING_KEY secret and in no file under git; the public key goes in App/Info.plist as
// BekitzurUpdatePublicKey, and the app installs only updates signed with the private key. Lose the private key and
// installed copies can't update themselves until a new public key reaches them by install.sh.
//
//   swift scripts/make-update-key.swift <file for the private key>
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("usage: swift scripts/make-update-key.swift <file for the private key>") }
let path = CommandLine.arguments[1]
guard !FileManager.default.fileExists(atPath: path) else { fatalError("\(path) exists; move it away first to make a new key") }
let key = Curve25519.Signing.PrivateKey()
try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600]) else {
    fatalError("couldn't write \(path)")
}
print(key.publicKey.rawRepresentation.base64EncodedString())
