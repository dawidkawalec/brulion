import Foundation

/// The app's technical identity in one place (docs/PRD.md section 4), so it runs next to
/// Captylo on the same Mac: its own bundle id, data folder, Keychain items, log subsystem and
/// URL scheme. The product is Brulion. These values never change after a public release (macOS
/// ties the permissions to the bundle id); the same values live in the `APP_*` build settings in
/// project.yml and at the top of the Makefile. Every UI string names the product "Brulion"
/// (`AppIdentityTests` checks the string catalogs and the Info.plist texts).
enum AppIdentity {
    /// Bundle id, also the Keychain service (`KeyStore`) and the log subsystem (`Log`).
    /// Must match `APP_BUNDLE_ID` in project.yml.
    static let bundleID = "pl.craftweb.brulion"
    /// `~/Library/Application Support/<dataFolderName>/` (`AppPaths`).
    static let dataFolderName = "Brulion"
    /// `<urlScheme>://` links. Must match `APP_URL_SCHEME` in project.yml.
    static let urlScheme = "brulion"
    /// The MCP server's `serverInfo.name` and its key in the assistant's config
    /// (`MCPSettingsRow`), so both apps can be connected side by side.
    static let mcpServerName = "brulion"
}
