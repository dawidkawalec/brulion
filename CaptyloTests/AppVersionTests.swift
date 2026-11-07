import Foundation
import Testing
@testable import Captylo

struct AppVersionTests {
    @Test func buildNumberIsAWholeNumberOnly() {
        #expect(AppVersion.buildNumber(info: ["CFBundleVersion": "142"]) == 142)
        #expect(AppVersion.buildNumber(info: ["CFBundleVersion": " 7 "]) == 7)
        #expect(AppVersion.buildNumber(info: ["CFBundleVersion": "abc"]) == nil)
        #expect(AppVersion.buildNumber(info: ["CFBundleVersion": "1.2"]) == nil)
        #expect(AppVersion.buildNumber(info: ["CFBundleVersion": "-3"]) == nil)
        #expect(AppVersion.buildNumber(info: [:]) == nil)
    }

    @Test func versionStringAddsTheBuildWhenThereIsOne() {
        let full: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "142"]
        #expect(AppVersion.versionString(info: full) == "1.0.0 (142)")
        #expect(AppVersion.versionString(info: ["CFBundleShortVersionString": "1.0.0"]) == "1.0.0")
        #expect(AppVersion.versionString(info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "abc"]) == "1.0.0")
        #expect(AppVersion.versionString(info: [:]) == "?")
    }

    @Test func versionLineIsTheLocalizedVersionLabel() throws {
        let full: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "142"]
        let version = "1.0.0 (142)"
        #expect(AppVersion.versionLine(info: full) == String(localized: "Wersja \(version)"))
        let enPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let en = try #require(Bundle(path: enPath))
        #expect(String(localized: "Wersja \(version)", bundle: en, locale: Locale(identifier: "en")) == "Version 1.0.0 (142)")
    }

    /// No update machinery is left in the bundle: nothing would ever check a feed.
    @Test func theAppHasNoUpdateFeed() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] == nil)
        #expect(info["SUPublicEDKey"] == nil)
    }
}
