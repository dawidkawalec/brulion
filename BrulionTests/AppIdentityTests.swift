import Foundation
import Testing
@testable import Brulion

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

    /// The product is Brulion: the values are pinned here, so a stray rename shows up at once.
    @Test func theIdentityIsBrulion() {
        #expect(AppIdentity.bundleID == "pl.craftweb.brulion")
        #expect(AppIdentity.dataFolderName == "Brulion")
        #expect(AppIdentity.urlScheme == "brulion")
        #expect(AppIdentity.mcpServerName == "brulion")
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

    /// The source catalogs, next to this file in the repo. Every UI string lives in one of them.
    private static let catalogs = [
        "Brulion/Resources/Localizable.xcstrings",
        "Brulion/LocalAI/LocalAI.xcstrings",
        "Brulion/Resources/InfoPlist.xcstrings",
    ]

    /// The product is Brulion in every UI text: no key, translation, plural or device variation
    /// in the string catalogs and no Info.plist text (permission prompts, the Services menu item,
    /// the app name) says "Captylo". The name stays only in code, comments and the credits.
    @Test func noUserFacingTextSaysCaptylo() throws {
        for text in try Self.userFacingTexts() where Self.saysCaptylo(text.value) {
            Issue.record("\(text.place): \"\(text.value)\"")
        }
    }

    /// Nor "Szpak", the product's name before Brulion, in any form ("Szpaka", "w Szpaku").
    @Test func noUserFacingTextSaysSzpak() throws {
        for text in try Self.userFacingTexts() where Self.saysSzpak(text.value) {
            Issue.record("\(text.place): \"\(text.value)\"")
        }
    }

    /// Every UI text with the place it comes from: the catalogs' keys and every string in their
    /// entries, the Info.plist prompts and Services, and the built InfoPlist.strings tables.
    private static func userFacingTexts() throws -> [(place: String, value: String)] {
        var found: [(place: String, value: String)] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in catalogs {
            let data = try Data(contentsOf: root.appending(path: path))
            let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(catalog["strings"] as? [String: Any], "\(path) has no strings")
            #expect(!strings.isEmpty, "\(path) has no strings")
            for (key, entry) in strings {
                found.append(("\(path): key", key))
                found += texts(in: entry).map { ("\(path): \"\(key)\" ->", $0) }
            }
        }

        let info = try #require(Bundle.main.infoDictionary)
        let prompts = [
            "NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription",
            "NSCalendarsFullAccessUsageDescription", "CFBundleName", "CFBundleDisplayName",
        ]
        for key in prompts {
            let text = try #require(info[key] as? String, "\(key) is missing")
            found.append((key, text))
        }
        let services = try #require(info["NSServices"] as? [[String: Any]])
        #expect(!services.isEmpty)
        found += texts(in: services).map { ("NSServices", $0) }
        for language in ["pl", "en"] {
            guard let url = Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: language),
                  let table = NSDictionary(contentsOf: url) as? [String: String] else { continue }
            for (key, text) in table {
                found.append(("\(language).lproj/InfoPlist.strings \(key)", text))
            }
        }
        return found
    }

    private static func saysCaptylo(_ text: String) -> Bool {
        text.range(of: "captylo", options: .caseInsensitive) != nil
    }

    private static func saysSzpak(_ text: String) -> Bool {
        text.range(of: "szpak", options: .caseInsensitive) != nil
    }

    /// Every string inside a catalog entry or a plist value (translations, variations,
    /// comments), depth first.
    private static func texts(in value: Any) -> [String] {
        switch value {
        case let text as String: [text]
        case let dictionary as [String: Any]: dictionary.values.flatMap { texts(in: $0) }
        case let array as [Any]: array.flatMap { texts(in: $0) }
        default: []
        }
    }
}
