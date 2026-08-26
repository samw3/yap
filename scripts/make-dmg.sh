#!/usr/bin/env bash
# Build, harden-sign, notarize, staple and pack Yap into a distributable DMG.
#
# The signing here is deliberately NOT what scripts/dev-run.sh does, and the two
# must not be conflated:
#
#   * Notarization requires the hardened runtime (--options runtime) and a secure
#     timestamp (--timestamp). dev-run.sh omits both on purpose.
#   * The hardened runtime revokes microphone access unless the bundle carries
#     com.apple.security.device.audio-input. The failure is silent -- the tap
#     delivers digital silence with no error anywhere -- so the entitlements file
#     and --options runtime always travel together.
#
# Everything is staged into dist/ from scratch. The dev app in ~/Applications is
# never touched, so its TCC grants survive a release build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${YAP_BUILD_DIR:-$ROOT/build}"
DIST="$ROOT/dist"
ENTITLEMENTS="$ROOT/bundle/yap.entitlements"
IDENTITY="${YAP_SIGN_IDENTITY:-Developer ID Application: Sam Washburn (266VNLKVKQ)}"
PROFILE="${YAP_NOTARY_PROFILE:-yap-notary}"
TEAM_ID="266VNLKVKQ"

NOTARIZE=1
STAPLE_APP=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
    # Second notarization round trip so the .app carries its own ticket, not just
    # the DMG. Costs another ~1 GB upload; worth it if users may first launch the
    # app offline, since an un-stapled app falls back to an online ticket lookup.
    --staple-app)    STAPLE_APP=1 ;;
    -h|--help)
      sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      echo
      echo "usage: $(basename "$0") [--skip-notarize] [--staple-app]"
      echo "env:   YAP_SIGN_IDENTITY, YAP_NOTARY_PROFILE, YAP_BUILD_DIR"
      exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

die() { echo "!! $*" >&2; exit 1; }

# $1 = file to upload, $2 = what to staple the returned ticket onto (default $1).
# They differ for a bare .app, which notarytool will only accept zipped.
notarize_and_staple() {
  local upload="$1" target="${2:-$1}"
  echo "==> notarize ${target##*/} (uploading $(du -h "$upload" | cut -f1); takes a few minutes)"
  xcrun notarytool submit "$upload" --keychain-profile "$PROFILE" --wait
  echo "==> staple ${target##*/}"
  xcrun stapler staple "$target"
}

echo "==> preflight"
# Note on the greps below and further down: `cmd | grep -q` is a trap under
# `set -o pipefail`, because grep exits at the first match, cmd takes SIGPIPE, and
# the pipeline then reports failure on success. Capture the output, then match it.
IDENTITIES="$(security find-identity -v -p codesigning)"
grep -qF "$IDENTITY" <<<"$IDENTITIES" \
  || die "signing identity not found: $IDENTITY
   available:
$(sed 's/^/   /' <<<"$IDENTITIES")"
[ -f "$ENTITLEMENTS" ] || die "missing $ENTITLEMENTS"
[ -d "$BUILD" ]        || die "no build directory at $BUILD -- configure it first"

# A Debug binary is several times slower on this workload and must never ship. The
# build type lives in the cache, so this is checkable rather than assumed.
BUILD_TYPE="$(sed -n 's/^CMAKE_BUILD_TYPE:STRING=//p' "$BUILD/CMakeCache.txt")"
[ "$BUILD_TYPE" = "Release" ] || [ "$BUILD_TYPE" = "RelWithDebInfo" ] \
  || die "build type is '${BUILD_TYPE:-<unset>}', refusing to ship it.
   Reconfigure with -DCMAKE_BUILD_TYPE=Release"

shopt -s nullglob
MODELS=("$ROOT"/models/*.gguf "$ROOT"/models/*.bin)
shopt -u nullglob
[ ${#MODELS[@]} -ge 2 ] || die "models missing from $ROOT/models -- run scripts/fetch-models.sh"

# Check credentials before the build rather than after: notarization is the last
# step, and finding out then wastes the whole run.
if [ "$NOTARIZE" = 1 ]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || die \
"no usable notarytool credentials for keychain profile '$PROFILE'.

   Create one once, in your own terminal. Omit --password: notarytool then gives
   you a secure prompt, so the secret stays out of shell history and out of argv,
   which any process on the machine can read via ps.

     xcrun notarytool store-credentials '$PROFILE' \\
       --apple-id <your-apple-id> --team-id $TEAM_ID

   Needs an app-specific password from appleid.apple.com (Sign-In and Security ->
   App-Specific Passwords), or use an App Store Connect API key instead:
   --key <path.p8> --key-id <id> --issuer <uuid>.

   Nothing after this reads the secret: the build only ever passes the profile
   NAME to notarytool. Or pass --skip-notarize to build an unnotarized DMG."
fi

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/bundle/Info.plist")"
# The app is staged inside the DMG's source folder rather than beside it, so the
# 1.1 GB of models is laid down once instead of being copied again to be packed.
STAGE="$DIST/dmg-root"
APP="$STAGE/Yap.app"
DMG="$DIST/Yap-$VER.dmg"
echo "    version $VER, identity ${IDENTITY##*: }, notarize=$NOTARIZE"

echo "==> build"
ninja -C "$BUILD" yap

echo "==> stage $APP"
# From scratch every time: a stale file left inside the bundle would be signed and
# shipped, and codesign cannot tell it was not meant to be there.
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/yap"              "$APP/Contents/MacOS/yap"
cp "$ROOT/bundle/Yap.icns"   "$APP/Contents/Resources/Yap.icns"
chmod +x "$APP/Contents/MacOS/yap"
for m in "${MODELS[@]}"; do
  cp -c "$m" "$APP/Contents/Resources/" 2>/dev/null || cp "$m" "$APP/Contents/Resources/"
done
# Extended attributes (quarantine flags, Finder metadata) make codesign fail with
# "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$APP"

echo "==> sign app (hardened runtime + entitlements + timestamp)"
# No --deep: it is deprecated and there is nothing nested to sign.
codesign --force --sign "$IDENTITY" \
         --options runtime --timestamp \
         --entitlements "$ENTITLEMENTS" \
         "$APP"

echo "==> verify signature"
codesign --verify --strict --verbose=2 "$APP"
# Both of these fail silently if they ever regress: without the runtime flag
# notarization rejects the upload, and without the entitlement the shipped app
# captures nothing but digital silence.
SIGN_INFO="$(codesign --display --verbose=4 "$APP" 2>&1)"
grep -qE 'flags=[^ ]*runtime' <<<"$SIGN_INFO" \
  || die "hardened runtime flag missing after signing:
$(grep -i 'CodeDirectory' <<<"$SIGN_INFO" | sed 's/^/   /')"
APP_ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
grep -q 'com.apple.security.device.audio-input' <<<"$APP_ENTS" \
  || die "audio-input entitlement missing after signing -- the shipped app would capture silence"
echo "    hardened runtime: yes, audio-input entitlement: yes"

if [ "$NOTARIZE" = 1 ] && [ "$STAPLE_APP" = 1 ]; then
  ZIP="$DIST/Yap-$VER-app.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"   # ditto, not zip: preserves the bundle
  notarize_and_staple "$ZIP" "$APP"
  rm -f "$ZIP"
fi

echo "==> build $DMG"
ln -sfn /Applications "$STAGE/Applications"   # the drag-to-install target
rm -f "$DMG"
# ULFO (lzfse) over UDZO: faster to make and to mount. The payload is ~1.1 GB of
# quantized model weights, which are near-incompressible either way.
hdiutil create -volname "Yap $VER" -srcfolder "$STAGE" \
               -fs HFS+ -format ULFO -ov "$DMG" >/dev/null

echo "==> sign DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  notarize_and_staple "$DMG"
  echo "==> verify notarization"
  xcrun stapler validate "$DMG"
  spctl -a -vvv -t open --context context:primary-signature "$DMG"
else
  echo "!! NOT notarized (--skip-notarize). Anyone who downloads this is told it"
  echo "   cannot be opened because Apple cannot check it for malicious software."
  echo "   Fine for testing on this machine; do not publish it."
fi

echo
echo "==> done: $DMG ($(du -h "$DMG" | cut -f1))"
echo "    signed app left staged at $APP"
echo "    Test before publishing, on a Mac that has never run Yap:"
echo "      1. mount the DMG, drag Yap.app to /Applications, launch it"
echo "      2. grant Microphone and Accessibility when asked"
echo "      3. hold F11 and dictate -- if text appears, the entitlements are right"
echo "    A hardened-runtime mic failure is silent, so step 3 is the only real check."
