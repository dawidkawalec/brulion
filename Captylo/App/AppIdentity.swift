import Foundation

/// The fork's technical identity in one place (docs/PRD.md section 4), so it can run next to
/// Captylo on the same Mac: its own bundle id, data folder, Keychain items, log subsystem and
/// URL scheme. These are working values until the owner picks the final name; the rename
/// changes this file, the identity variables at the top of the Makefile and the `APP_*` build
/// settings in project.yml. The word "Captylo" in UI strings is a separate pass.
enum AppIdentity {
    /// Bundle id, also the Keychain service (`KeyStore`) and the log subsystem (`Log`).
    /// Must match `APP_BUNDLE_ID` in project.yml.
    static let bundleID = "pl.craftweb.captylobielik"
    /// `~/Library/Application Support/<dataFolderName>/` (`AppPaths`).
    static let dataFolderName = "CaptyloBielik"
    /// `<urlScheme>://` links. Must match `APP_URL_SCHEME` in project.yml.
    static let urlScheme = "captylobielik"
    /// The MCP server's `serverInfo.name` and its key in the assistant's config
    /// (`MCPSettingsRow`), so both apps can be connected side by side.
    static let mcpServerName = "captylobielik"
}
