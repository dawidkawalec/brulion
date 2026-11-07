import Foundation
import ServiceManagement
import Testing
@testable import Captylo

struct LaunchAtLoginTests {
    private let home = "/Users/someone"

    @Test func aCopyInApplicationsCanRegisterEvenWhenNotFound() {
        let url = URL(fileURLWithPath: "/Applications/Szpak.app")
        #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home) == false)
    }

    @Test func aCopyInTheUsersApplicationsCanRegisterToo() {
        let url = URL(fileURLWithPath: "/Users/someone/Applications/Szpak.app")
        #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home) == false)
    }

    @Test func buildFoldersAndTranslocatedCopiesStayUnavailable() {
        let paths = [
            "/Users/someone/Downloads/Szpak.app",
            "/Users/someone/code/captylo/.local-build/Build/Products/Debug/Szpak.app",
            "/private/var/folders/xy/T/AppTranslocation/1234/d/Szpak.app",
            "/Volumes/Szpak/Szpak.app",
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home), "\(path)")
        }
    }

    @Test func otherStatusesNeverBlockTheSwitch() {
        let url = URL(fileURLWithPath: "/Users/someone/Downloads/Szpak.app")
        for status in [SMAppService.Status.notRegistered, .enabled, .requiresApproval] {
            #expect(LaunchAtLogin.isUnavailable(status: status, bundleURL: url, home: home) == false)
        }
    }
}
