# Releasing

How a public version gets from this repository to a signed, notarized DMG on a GitHub release. There is no update feed and no automatic update check: people download new versions by hand. Short on purpose; the script prints every step and stops with a clear message when something is missing.

Pieces: `scripts/release.sh` (`make dist`, `make dist-dry`), `scripts/sign-app.sh` (inside-out signing), `scripts/make-dmg.sh`. The product name comes from `PRODUCT` in the Makefile (`APP_PRODUCT_NAME` in `project.yml`, see "Identity" in [architecture.md](architecture.md)). Background: "Signing" in [architecture.md](architecture.md).

## Once

1. **Developer ID certificate.** Xcode > Settings > Accounts > the team > Manage Certificates > "+" > Developer ID Application. It lands in the login Keychain. Check: `security find-identity -v -p codesigning | grep "Developer ID Application"` prints exactly one line (with more than one, run `make dist DIST_IDENTITY="<full certificate name>"`). Keep a `.p12` export with its password outside the repo. The first real signature makes macOS ask whether codesign may use the key: type the login password and choose "Always Allow", or every later signature waits for that prompt.
2. **Notarization profile.** Create an App Store Connect API key (Users and Access > Integrations > App Store Connect API, role Developer), download `AuthKey_<KEYID>.p8` into a private folder outside the repo (chmod 600), then:
   `xcrun notarytool store-credentials captylo-notary --key <folder>/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER>`.
   The profile lives in the login Keychain. An app-specific password works too (`--apple-id`, `--team-id`, `--password`). Another profile name goes through `NOTARY_PROFILE=<name>`.

## Every release

1. **Version.** Bump `MARKETING_VERSION` in `project.yml` by hand, commit. The build number is not edited anywhere: `CFBundleVersion` = `git rev-list --count HEAD` when the release is built, so it grows with every release cut from `main`.
2. **Optional rehearsal.** `make dist-dry VERSION=<version>`: same build, signed with "Captylo Dev", no notarization, nothing leaves the Mac. It lists what a real run would refuse.
3. **Build.** On `main` with a clean tree: `make dist VERSION=<version>`. It checks the prerequisites above, builds, signs inside-out, notarizes the app (as a zip) and staples it, packages and signs the DMG, notarizes and staples the DMG, mounts it and launches the app from it (`--mcp` with stdin closed), and asks Gatekeeper (`spctl`). The result is `dist/<version>/<Product>-<version>.dmg` with its SHA-256. Notarization usually takes a few minutes; the script waits up to 30.
4. **Publish.** Only with the owner's go-ahead: a GitHub release `v<version>` with the DMG and short notes, created by hand (`gh release create`). Nothing in this repo uploads anything.

## When notarization is rejected

`release.sh` prints Apple's log (`xcrun notarytool log <id> --keychain-profile captylo-notary`). Almost always a nested binary without the hardened runtime, without a secure timestamp or not signed by Developer ID: look for the path in the log, check `codesign -dvvv <path>` on `dist/<version>/<Product>.app`, fix `scripts/sign-app.sh` if a new nested item appeared (a framework, an XPC service or a helper such as a bundled model server), and run `make dist` again. Nothing was published, so a rerun is harmless. `spctl -a -vv dist/<version>/<Product>.app` should end with "source=Notarized Developer ID".

## Keys and what losing them means

- **Developer ID certificate** (login Keychain, `.p12` backup): a renewed or replacement certificate from the same team keeps people's permissions working, because the app's designated requirement names the team, not one certificate.
- **Notary API key** (`AuthKey_<KEYID>.p8`): can be revoked and created again at any time; rerun `store-credentials`.

Never commit a `.p12`, a `.p8`, a key file or a password; `.gitignore` covers them and `dist/`.

## Permissions after the switch to Developer ID

The released app has a different signature from development builds ("Captylo Dev" or ad-hoc), so on a Mac that ran a development build macOS asks for Microphone, Accessibility, Calendar and System Audio once more. That is expected; there is no migration. Development builds keep their own grants (`make reset-tcc` resets them).
