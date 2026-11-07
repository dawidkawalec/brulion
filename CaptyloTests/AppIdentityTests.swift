import Foundation
import Testing
@testable import Captylo

/// The fork's identity lives in AppIdentity.swift, project.yml and the Makefile: these checks
/// catch a rename that missed one of them, and a value that would collide with Captylo's.
struct AppIdentityTests {
    /// The test host is the app itself, so its Info.plist shows what project.yml built.
    @Test func theBuiltAppMatchesAppIdentity() throws {
        #expect(Bundle.main.bundleIdentifier == AppIdentity.bundleID)
        let schemes = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == [AppIdentity.urlScheme])
    }

    @Test func servicesFollowTheIdentity() {
        #expect(KeyStore.defaultService == AppIdentity.bundleID)
        #expect(Log.subsystem == AppIdentity.bundleID)
        #expect(AppPaths.folderName == AppIdentity.dataFolderName)
    }

    @MainActor
    @Test func nothingCollidesWithCaptylo() {
        #expect(AppIdentity.bundleID != "com.captylo.app")
        #expect(AppIdentity.dataFolderName != "Captylo")
        #expect(AppIdentity.urlScheme != "captylo")
        #expect(AppIdentity.mcpServerName != "captylo")
        #expect(Hotkey.defaultHotkey != .rightOption)
        for combo in [GlobalShortcut.meeting, GlobalShortcut.note, GlobalShortcut.correction] {
            #expect(!combo.display.hasPrefix("⌃⌥⌘"))
        }
    }
}
