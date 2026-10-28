import CryptoKit
import Foundation
import Testing
@testable import BekitzurUpdates

struct UpdaterTests {
    private let key = Curve25519.Signing.PrivateKey()

    private func manifest(version: String = "0.3.0", build: String = "202611011200", sha256: String = "ab12", signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws -> UpdateManifest {
        let unsigned = UpdateManifest(version: version, build: build, url: URL(string: "https://example.com/Bekitzur.zip")!, sha256: sha256, notes: "", signature: "")
        let signature = try (signer ?? key).signature(for: unsigned.signedMessage).base64EncodedString()
        return UpdateManifest(version: version, build: build, url: unsigned.url, sha256: sha256, notes: "", signature: signature)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bekitzur-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A bundle around a copy of /usr/bin/true, signed ad hoc as `identifier` the way the build scripts sign Bekitzur.
    private func app(in folder: URL, identifier: String) throws -> URL {
        let app = folder.appending(path: "Bekitzur.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Bekitzur", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: app.appending(path: "Contents/MacOS/Bekitzur"))
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--requirements", "=designated => identifier \"\(identifier)\"", app.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        return app
    }

    @Test func aReleaseSignedWithTheReleaseKeyIsAccepted() throws {
        #expect(try manifest().isSigned(by: key.publicKey))
    }

    @Test func changingWhatWasSignedOrSigningWithAnotherKeyIsRefused() throws {
        let signed = try manifest()
        for altered in [
            UpdateManifest(version: "9.9.9", build: signed.build, url: signed.url, sha256: signed.sha256, notes: "", signature: signed.signature),
            UpdateManifest(version: signed.version, build: "209901010000", url: signed.url, sha256: signed.sha256, notes: "", signature: signed.signature),
            UpdateManifest(version: signed.version, build: signed.build, url: signed.url, sha256: "ff00", notes: "", signature: signed.signature),
        ] {
            #expect(!altered.isSigned(by: key.publicKey))
        }
        #expect(try !manifest(signedBy: Curve25519.Signing.PrivateKey()).isSigned(by: key.publicKey))
    }

    @Test func onlyALaterBuildIsAnUpdate() throws {
        let release = try manifest(build: "202611011200")
        #expect(release.isNewer(than: "202610281119"))
        #expect(!release.isNewer(than: "202611011200"))
        #expect(!release.isNewer(than: "202611021200"))
    }

    /// As the release workflow writes it.
    @Test func updateJSONDecodes() throws {
        let json = #"{"version": "0.2.0", "build": "202610281400", "url": "https://github.com/a/b/releases/download/v0.2.0/Bekitzur.zip", "sha256": "ab12", "notes": "First release", "signature": "c2ln"}"#
        let decoded = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(decoded.version == "0.2.0" && decoded.build == "202610281400" && decoded.notes == "First release")
    }

    @Test func anUpdaterNeedsAFeedAndAValidKey() {
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        #expect(Updater(feed: "https://example.com/update.json", publicKey: publicKey, build: "1") != nil)
        #expect(Updater(feed: nil, publicKey: publicKey, build: "1") == nil)
        #expect(Updater(feed: "https://example.com/update.json", publicKey: "not a key", build: "1") == nil)
    }

    @Test func theChecksumIsSHA256() throws {
        let file = try folder().appending(path: "abc")
        try Data("abc".utf8).write(to: file)
        #expect(try Updater.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func theAppIsFoundInTheReleaseLayout() throws {
        let root = try folder()
        let app = try self.app(in: root.appending(path: "Bekitzur"), identifier: "app.bekitzur.mac")
        #expect(Updater.app(in: root)?.standardizedFileURL == app.standardizedFileURL)
        #expect(Updater.app(in: try folder()) == nil)
    }

    @Test func anAppSignedAsBekitzurPassesAndAnyOtherIsRefused() throws {
        try Updater.checkSignature(of: app(in: folder(), identifier: "app.bekitzur.mac"))
        #expect(throws: UpdateError.self) { try Updater.checkSignature(of: app(in: folder(), identifier: "com.example.other")) }
    }

    @Test func replacingMovesTheNewAppInAndCleansUpTheOldOneLater() throws {
        let applications = try folder(), downloads = try folder()
        let current = applications.appending(path: "Bekitzur.app"), new = downloads.appending(path: "Bekitzur.app")
        for (app, marker) in [(current, "old"), (new, "new")] {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: app.appending(path: "marker"))
        }

        try Updater.replace(current, with: new)

        #expect(try String(contentsOf: current.appending(path: "marker"), encoding: .utf8) == "new")
        let aside = try FileManager.default.contentsOfDirectory(atPath: applications.path).filter { $0.hasPrefix(Updater.leftoverPrefix) }
        #expect(aside.count == 1)
        Updater.removeLeftovers(beside: current)
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Bekitzur.app"])
    }
}
