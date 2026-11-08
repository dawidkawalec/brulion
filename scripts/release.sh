#!/bin/bash
# Builds a release: Release build, Developer ID signature, notarization, stapled DMG.
# There is no update feed: the DMG goes to a GitHub release by hand (docs/release.md).
#
#   scripts/release.sh <version> [--allow-branch]      (make dist VERSION=1.0.0)
#   DRY_RUN=1 scripts/release.sh <version> --allow-branch   (make dist-dry VERSION=1.0.0)
#
# Order: build -> sign the app inside-out -> notarize the app (zip) -> staple the app ->
# DMG -> sign the DMG -> notarize the DMG -> staple the DMG -> check.
# Both submissions, so the app inside the DMG carries its own ticket too.
#
# A dry run signs with the local "Captylo Dev" identity (make sign), leaves the DMG unsigned,
# skips notarization and stapling, and reports what a real run would refuse instead of stopping.
#
# Environment: PRODUCT (the app's name, APP_PRODUCT_NAME in project.yml; make passes it),
# DIST_IDENTITY (default "Developer ID Application", matched by codesign as a prefix of the
# certificate name), NOTARY_PROFILE (default captylo-notary, a notarytool Keychain profile),
# DRY_RUN=1. Secrets come only from the Keychain: the identity and the notary profile; nothing
# is read from or written to the repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST_IDENTITY="${DIST_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-captylo-notary}"
DRY_RUN="${DRY_RUN:-0}"
DERIVED="$ROOT/.local-build"
PRODUCT="${PRODUCT:-$(sed -n 's/^ *APP_PRODUCT_NAME: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)}"

usage() {
  echo "usage: [DRY_RUN=1] $0 <version> [--allow-branch]" >&2
  exit 2
}

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\nrelease.sh: %s\n' "$*" >&2; exit 1; }
dry() { [ "$DRY_RUN" = "1" ]; }

# refuse MESSAGE: stops a real release, only reports in a dry run.
refuse() {
  if dry; then note "DRY RUN, a real release would stop here: $*"; else die "$*"; fi
}

[ $# -ge 1 ] || usage
VERSION="$1"
shift
ALLOW_BRANCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-branch) ALLOW_BRANCH=1; shift ;;
    *) usage ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "The version must look like 1.2.3, got \"$VERSION\""
[ -n "$PRODUCT" ] || die "No product name (APP_PRODUCT_NAME in project.yml)"

OUT="$ROOT/dist/$VERSION"
APP="$OUT/$PRODUCT.app"
DMG="$OUT/$PRODUCT-$VERSION.dmg"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/$PRODUCT-release.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if dry; then
  printf '%s %s: DRY RUN (Captylo Dev signature, no notarization, nothing leaves this Mac)\n' "$PRODUCT" "$VERSION"
else
  printf '%s %s: release build\n' "$PRODUCT" "$VERSION"
fi

# 1. Guards

step "Checking the repository and the release prerequisites"
BRANCH="$(git branch --show-current)"
if [ "$BRANCH" = "main" ]; then
  note "Branch: main"
elif [ "$ALLOW_BRANCH" = "1" ]; then
  note "Branch: $BRANCH (allowed with --allow-branch)"
else
  die "Releases are cut from main, this is \"$BRANCH\" (pass --allow-branch to override)"
fi

if [ -n "$(git status --porcelain)" ]; then
  refuse "The working tree has uncommitted changes (commit or stash them first)"
else
  note "Working tree: clean"
fi

MARKETING_VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
[ "$MARKETING_VERSION" = "$VERSION" ] ||
  die "project.yml says MARKETING_VERSION \"$MARKETING_VERSION\", not \"$VERSION\" (bump it by hand and commit first)"
note "MARKETING_VERSION: $MARKETING_VERSION"

VALID_IDENTITIES="$(security find-identity -v -p codesigning | grep -cF "\"$DIST_IDENTITY" || true)"
if [ "$VALID_IDENTITIES" = "1" ]; then
  note "Signing identity: one valid \"$DIST_IDENTITY...\" in the Keychain"
elif [ "$VALID_IDENTITIES" = "0" ]; then
  refuse "No valid \"$DIST_IDENTITY\" signing identity in the Keychain (docs/release.md, Developer ID certificate)"
else
  refuse "$VALID_IDENTITIES identities match \"$DIST_IDENTITY\": set DIST_IDENTITY to the full certificate name"
fi

if dry; then
  # Local look only, no request to Apple. Older notarytool kept saved profiles as a generic
  # password item named after the profile; newer versions keep them where `security` cannot
  # see them (a working profile was missed here on 2026-11-08), so a miss is only a hint. The
  # real run asks notarytool itself and stops if the profile does not work.
  if security find-generic-password -a "com.apple.gke.notary.tool.saved-creds.$NOTARY_PROFILE" >/dev/null 2>&1; then
    note "Notary profile \"$NOTARY_PROFILE\": looks present in the Keychain (not checked against Apple in a dry run)"
  else
    note "Notary profile \"$NOTARY_PROFILE\": not visible to \`security\` (newer notarytool hides it); check with: xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
  fi
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  note "Notary profile \"$NOTARY_PROFILE\": works"
else
  die "The notarytool profile \"$NOTARY_PROFILE\" is missing or rejected (xcrun notarytool store-credentials $NOTARY_PROFILE ..., docs/release.md)"
fi

# 2. Build

# The build number only has to grow with every release: the commit count does that on main.
BUILD="$(git rev-list --count HEAD)"
step "Building $PRODUCT $VERSION (build $BUILD), Release"
mkdir -p "$OUT"
# Spotlight would list every release's app next to the installed one.
touch "$ROOT/dist/.metadata_never_index"
make --no-print-directory gen >/dev/null
BUILD_LOG="$OUT/build.log"
if ! xcodebuild -project Captylo.xcodeproj -scheme Captylo -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation -configuration Release \
  CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGN_IDENTITY="-" build >"$BUILD_LOG" 2>&1; then
  grep -E 'error:' "$BUILD_LOG" | head -20 || tail -40 "$BUILD_LOG"
  die "xcodebuild failed, full log in ${BUILD_LOG#"$ROOT"/}"
fi
note "** BUILD SUCCEEDED ** (log in ${BUILD_LOG#"$ROOT"/})"

rm -rf "$APP"
ditto "$DERIVED/Build/Products/Release/$PRODUCT.app" "$APP"
xattr -cr "$APP"
PLIST="$APP/Contents/Info.plist"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[ "$BUILT_VERSION" = "$VERSION" ] || die "The built app says version $BUILT_VERSION, expected $VERSION"
[ "$BUILT_BUILD" = "$BUILD" ] || die "The built app says build $BUILT_BUILD, expected $BUILD"
note "Copied to ${APP#"$ROOT"/} (CFBundleShortVersionString $BUILT_VERSION, CFBundleVersion $BUILT_BUILD)"

# 3. Sign the app

if dry; then
  step "Signing the app with the development identity (make sign)"
  make --no-print-directory sign APP_PATH="$APP"
else
  step "Signing the app inside-out with \"$DIST_IDENTITY\""
  note "If macOS asks to let codesign use the Developer ID key, choose \"Always Allow\" (once)"
  "$ROOT/scripts/sign-app.sh" "$APP" "$DIST_IDENTITY" --entitlements "$ROOT/Captylo/Captylo.entitlements"
fi

# notarize FILE LABEL: submits to Apple and waits; anything but Accepted prints the log and stops.
notarize() {
  local file="$1" label="$2" result id status
  note "Submitting $label to Apple (this waits for the verdict, up to 30 min)"
  result="$WORK/notary-$label.json"
  if ! xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
    --output-format json >"$result"; then
    cat "$result" >&2 || true
  fi
  id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$result" 2>/dev/null || true)"
  status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$result" 2>/dev/null || true)"
  note "Notarization of $label: ${status:-no answer} (id ${id:-none})"
  if [ "$status" != "Accepted" ]; then
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "Apple did not accept $label (see the log above; docs/release.md, \"Rejected\")"
  fi
}

# 4. Notarize and staple the app

if dry; then
  step "Notarizing the app: skipped (dry run)"
else
  step "Notarizing the app"
  ditto -c -k --keepParent "$APP" "$WORK/$PRODUCT-$VERSION.zip"
  notarize "$WORK/$PRODUCT-$VERSION.zip" app
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# 5. DMG

step "Packaging ${DMG#"$ROOT"/}"
if dry; then
  "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" "$PRODUCT"
else
  "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" "$PRODUCT" --sign "$DIST_IDENTITY"
fi

# 6. Notarize and staple the DMG

if dry; then
  step "Notarizing the DMG: skipped (dry run)"
else
  step "Notarizing the DMG"
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# 7. Check what people will download

step "Checking the DMG"
MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null
[ -d "$MOUNT/$PRODUCT.app" ] || die "No $PRODUCT.app in the DMG"
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] || die "No Applications shortcut in the DMG"
note "Mounted: $PRODUCT.app and the Applications shortcut are there"
codesign --verify --deep --strict "$MOUNT/$PRODUCT.app"
note "codesign --verify --deep --strict: valid"
# --mcp runs before AppKit (no UI, no services) and exits when stdin closes; it still makes
# dyld load every linked library, so a signature mismatch of a nested item fails right here.
"$MOUNT/$PRODUCT.app/Contents/MacOS/$PRODUCT" --mcp </dev/null >/dev/null 2>"$WORK/launch.log" ||
  { cat "$WORK/launch.log" >&2; die "The app from the DMG does not launch"; }
note "Launch check (--mcp, stdin closed): exit 0"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

if spctl --assess --type open --context context:primary-signature -v "$DMG" 2>"$WORK/spctl-dmg.log"; then
  note "spctl (DMG): $(tr '\n' ' ' <"$WORK/spctl-dmg.log")"
elif dry; then
  note "spctl (DMG): rejected, as expected without Developer ID and notarization"
else
  cat "$WORK/spctl-dmg.log" >&2
  die "Gatekeeper rejects the DMG"
fi
if spctl -a -vv "$APP" 2>"$WORK/spctl-app.log"; then
  note "spctl (app): $(tr '\n' ' ' <"$WORK/spctl-app.log")"
elif dry; then
  note "spctl (app): rejected, as expected without Developer ID and notarization"
else
  cat "$WORK/spctl-app.log" >&2
  die "Gatekeeper rejects the app"
fi

# 8. Next

step "Done"
note "DMG:     ${DMG#"$ROOT"/} ($(stat -f%z "$DMG") bytes)"
note "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if dry; then
  note "Dry run: nothing was notarized or signed for distribution."
else
  note "Next: a GitHub release v$VERSION with the DMG, by hand and only with the owner's go-ahead (docs/release.md)."
fi
