#!/usr/bin/env bash
# Compliance checks from docs/SECURITY_AND_APP_STORE.md that can be automated. Runs on macOS (uses plutil).
# Usage: scripts/check-compliance.sh [path/to/Ereader.app]
#   Without an argument it checks the source files; with a built .app it also checks the bundle.
set -euo pipefail

failures=0
fail() { echo "::error::$1"; failures=$((failures + 1)); }
pass() { echo "ok: $1"; }

plist_value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
has_key() { plutil -extract "$2" xml1 -o /dev/null "$1" > /dev/null 2>&1; }

INFO=App/Info.plist
ENTITLEMENTS=App/Ereader.entitlements
PRIVACY=App/Resources/PrivacyInfo.xcprivacy

for f in "$INFO" "$ENTITLEMENTS" "$PRIVACY"; do
    plutil -lint "$f" > /dev/null || fail "$f is not a valid property list"
done

# App Transport Security: no exceptions at all.
if has_key "$INFO" NSAppTransportSecurity; then
    fail "$INFO must not contain NSAppTransportSecurity (no ATS exceptions)"
else
    pass "no ATS exceptions"
fi

# Export compliance: only OS-provided encryption.
[ "$(plist_value "$INFO" ITSAppUsesNonExemptEncryption)" = "false" ] \
    && pass "ITSAppUsesNonExemptEncryption = NO" \
    || fail "$INFO must set ITSAppUsesNonExemptEncryption to false"

# Data Protection default class.
# (plutil key paths treat "." as a separator, so read this dotted key with PlistBuddy.)
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.default-data-protection' "$ENTITLEMENTS" 2>/dev/null || true)" \
    = "NSFileProtectionCompleteUntilFirstUserAuthentication" ] \
    && pass "default Data Protection class" \
    || fail "$ENTITLEMENTS must set default-data-protection to NSFileProtectionCompleteUntilFirstUserAuthentication"

# Privacy manifest: no tracking, nothing collected.
[ "$(plist_value "$PRIVACY" NSPrivacyTracking)" = "false" ] \
    && pass "NSPrivacyTracking = false" || fail "$PRIVACY must set NSPrivacyTracking to false"
[ "$(plist_value "$PRIVACY" NSPrivacyTrackingDomains)" = "0" ] \
    && pass "no tracking domains" || fail "$PRIVACY must list no tracking domains"
[ "$(plist_value "$PRIVACY" NSPrivacyCollectedDataTypes)" = "0" ] \
    && pass "no collected data types" || fail "$PRIVACY must list no collected data types (or update the docs)"

# Required-reason APIs: every category our sources use must be declared in the privacy manifest.
# Third-party packages are checked by hand when they are added or updated (docs/SECURITY_AND_APP_STORE.md).
check_api() {
    local category="$1" pattern="$2"
    if grep -rqE "$pattern" App Packages/EreaderKit/Sources --include='*.swift'; then
        if grep -q "NSPrivacyAccessedAPICategory$category<" "$PRIVACY"; then
            pass "required-reason API category $category is declared"
        else
            fail "sources use a $category API ($pattern) but $PRIVACY doesn't declare it"
        fi
    fi
}
check_api FileTimestamp 'creationDate|[mM]odificationDate|attributesOfItem|getattrlist|(^|[^A-Za-z_.])[fl]?stat\('
check_api SystemBootTime 'systemUptime|mach_absolute_time'
check_api DiskSpace 'volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize|statfs|NSFileSystemFree'
check_api ActiveKeyboards 'activeInputModes'
check_api UserDefaults 'UserDefaults|@AppStorage'

# Built bundle, when given.
if [ $# -ge 1 ]; then
    APP="$1"
    [ -f "$APP/PrivacyInfo.xcprivacy" ] \
        && pass "privacy manifest is in the app bundle" \
        || fail "PrivacyInfo.xcprivacy is missing from $APP"
    if has_key "$APP/Info.plist" NSAppTransportSecurity; then
        fail "built Info.plist contains NSAppTransportSecurity"
    fi
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures compliance check(s) failed"
    exit 1
fi
echo "All compliance checks passed"
