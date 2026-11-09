import Foundation
import ServiceManagement
import Testing
@testable import Brulion

struct LaunchAtLoginTests {
    private let home = "/Users/someone"

    @Test func aCopyInApplicationsCanRegisterEvenWhenNotFound() {
        let url = URL(fileURLWithPath: "/Applications/Brulion.app")
        #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home) == false)
    }

    @Test func aCopyInTheUsersApplicationsCanRegisterToo() {
        let url = URL(fileURLWithPath: "/Users/someone/Applications/Brulion.app")
        #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home) == false)
    }

    @Test func buildFoldersAndTranslocatedCopiesStayUnavailable() {
        let paths = [
            "/Users/someone/Downloads/Brulion.app",
            "/Users/someone/code/brulion/.local-build/Build/Products/Debug/Brulion.app",
            "/private/var/folders/xy/T/AppTranslocation/1234/d/Brulion.app",
            "/Volumes/Brulion/Brulion.app",
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home), "\(path)")
        }
    }

    @Test func otherStatusesNeverBlockTheSwitch() {
        let url = URL(fileURLWithPath: "/Users/someone/Downloads/Brulion.app")
        for status in [SMAppService.Status.notRegistered, .enabled, .requiresApproval] {
            #expect(LaunchAtLogin.isUnavailable(status: status, bundleURL: url, home: home) == false)
        }
    }
}
