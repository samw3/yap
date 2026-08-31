#!/usr/bin/env bash
# Build, notarize and publish a Yap release in one shot: make-dmg.sh, then a
# GitHub release that existing installs will actually be offered.
#
# The publish half is not just `gh release create`. Everything an installed copy
# checks before it will replace itself is checked here first, because the app is
# the strict party and a release it refuses is a release nobody gets:
#
#   * the release TAG is what the app compares against its own
#     CFBundleShortVersionString -- not the asset name -- so it must be v<version>
#   * the app reads /releases/latest, which excludes drafts. So the asset is
#     uploaded to a DRAFT and the release is flipped to published only once the
#     bytes are confirmed to have landed. A release that goes public mid-upload is
#     a release whose .dmg is half a disk image.
#   * at install time the app re-verifies the bundle inside the DMG against
#     `anchor apple generic and identifier <bundle-id> and leaf OU = <team-id>`,
#     and refuses a disk image whose Info.plist version disagrees with the tag.
#     Both are checked here, on the exact file about to be uploaded.
#
# The repo, bundle id and team id are read out of src/update.mm rather than
# repeated: the app decides what a valid release is, so it is the source of truth.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
UPDATE_MM="$ROOT/src/update.mm"

REUSE_DMG=0
DRY_RUN=0
ASSUME_YES=0
REPLACE_DRAFT=0
NOTES_FILE=""
NOTES_TEXT=""
DMG_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --reuse-dmg)     REUSE_DMG=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    -y|--yes)        ASSUME_YES=1 ;;
    --replace-draft) REPLACE_DRAFT=1 ;;
    --notes-file=*)  NOTES_FILE="${arg#*=}" ;;
    --notes=*)       NOTES_TEXT="${arg#*=}" ;;
    # Passed straight through to make-dmg.sh.
    --skip-notarize|--staple-app) DMG_ARGS+=("$arg") ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      echo
      echo "usage: $(basename "$0") [--reuse-dmg] [--replace-draft] [--yes] [--dry-run]"
      echo "                        [--notes-file=F | --notes=TEXT]"
      echo "                        [--skip-notarize] [--staple-app]"
      echo
      echo "  --reuse-dmg      publish dist/Yap-<version>.dmg as it stands; skip the build"
      echo "  --replace-draft  delete an existing DRAFT release for this tag and remake it"
      echo "  --dry-run        do everything except create the release"
      echo "  --notes-file=F   release notes from a file (default: commit subjects since"
      echo "                   the last release)"
      echo "  env: YAP_SIGN_IDENTITY, YAP_NOTARY_PROFILE, YAP_BUILD_DIR (see make-dmg.sh)"
      exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

die() { echo "!! $*" >&2; exit 1; }

# <0 / 0 / >0, on the leading dotted-numeric components only. This mirrors
# yap::version_compare in src/version.h, and exists for the same reason: compared
# as text "0.10.0" sorts before "0.9.0", and a release the installed copies read
# as older is one none of them will ever be offered.
version_cmp() {
  local a b i x y
  IFS=. read -r -a a <<<"${1#v}"
  IFS=. read -r -a b <<<"${2#v}"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    if ((10#${x:-0} != 10#${y:-0})); then
      ((10#${x:-0} < 10#${y:-0})) && { echo -1; return; } || { echo 1; return; }
    fi
  done
  echo 0
}

# ---------------------------------------------------------------------------
# preflight -- all of it before the build, because notarization is a ~1 GB
# upload and discovering a bad tag afterwards wastes the whole run
# ---------------------------------------------------------------------------

echo "==> preflight"

[ -f "$UPDATE_MM" ] || die "missing $UPDATE_MM -- cannot tell which repo the app polls"
# `cmd | grep -q` is a trap under pipefail: grep exits at the first match, cmd
# takes SIGPIPE, and the pipeline reports failure on success. Capture, then match.
UPDATE_SRC="$(cat "$UPDATE_MM")"
SLUG="$(sed -n 's|.*api\.github\.com/repos/\([^/"]*/[^/"]*\)/releases/latest.*|\1|p' <<<"$UPDATE_SRC" | head -1)"
BUNDLE_ID="$(sed -n 's/.*kBundleID *= *@"\([^"]*\)".*/\1/p' <<<"$UPDATE_SRC" | head -1)"
TEAM_ID="$(sed -n 's/.*kTeamID *= *@"\([^"]*\)".*/\1/p' <<<"$UPDATE_SRC" | head -1)"
APP_NAME="$(sed -n 's/.*kAppName *= *@"\([^"]*\)".*/\1/p' <<<"$UPDATE_SRC" | head -1)"
[ -n "$SLUG" ]      || die "could not find the releases URL in $UPDATE_MM"
[ -n "$BUNDLE_ID" ] || die "could not find kBundleID in $UPDATE_MM"
[ -n "$TEAM_ID" ]   || die "could not find kTeamID in $UPDATE_MM"
APP_NAME="${APP_NAME:-Yap.app}"

command -v gh >/dev/null || die "gh is not installed (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated -- run: gh auth login"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/bundle/Info.plist")"
BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/bundle/Info.plist")"
[ -n "$VER" ] || die "no CFBundleShortVersionString in bundle/Info.plist"
TAG="v$VER"
DMG="$DIST/Yap-$VER.dmg"
echo "    $SLUG, tag $TAG (build $BUILD_NO), asset ${DMG##*/}"

# The tag is created from a commit the remote must already have, and the version
# bump belongs in that commit -- so a dirty tree means the release would be tagged
# at something that is not what was built.
DIRTY="$(git -C "$ROOT" status --porcelain)"
[ -z "$DIRTY" ] || die "working tree is not clean; commit the version bump first:
$(sed 's/^/   /' <<<"$DIRTY")"

SHA="$(git -C "$ROOT" rev-parse HEAD)"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
git -C "$ROOT" fetch --quiet origin || die "could not reach origin"
REMOTE_HAS="$(git -C "$ROOT" branch -r --contains "$SHA" 2>/dev/null || true)"
[ -n "$REMOTE_HAS" ] || die "HEAD ($(git -C "$ROOT" log -1 --format='%h %s')) is not on origin.
   The release tag has to point at a commit GitHub already has:
     git push origin $BRANCH"

EXISTING_TAG="$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$TAG" || true)"
if [ -n "$EXISTING_TAG" ]; then
  TAGGED_SHA="$(awk '{print $1}' <<<"$EXISTING_TAG")"
  [ "$TAGGED_SHA" = "$SHA" ] || die "$TAG already exists on origin at ${TAGGED_SHA:0:8}, but HEAD is ${SHA:0:8}.
   Bump the version rather than moving a published tag."
fi

# An existing release for this tag: a draft is a previous run that did not finish
# and can be remade; a published one is what every install is reading right now,
# and clobbering it is a decision to make by hand.
REL_STATE=""
if REL_JSON="$(gh release view "$TAG" --repo "$SLUG" --json isDraft,url 2>/dev/null)"; then
  case "$REL_JSON" in
    *'"isDraft":true'*)  REL_STATE=draft ;;
    *)                   REL_STATE=published ;;
  esac
fi
if [ "$REL_STATE" = published ]; then
  die "a PUBLISHED release already exists for $TAG.
   Installed copies are reading it. Bump the version, or remove it deliberately:
     gh release delete $TAG --repo $SLUG --cleanup-tag"
elif [ "$REL_STATE" = draft ] && [ "$REPLACE_DRAFT" = 0 ]; then
  die "a draft release already exists for $TAG (a run that did not finish).
   Re-run with --replace-draft to delete and remake it, or finish it by hand."
fi

# The updater compares tags, so a release that is not newer than the current
# /releases/latest is one no installed copy will ever act on.
LATEST_TAG="$(gh api "repos/$SLUG/releases/latest" --jq .tag_name 2>/dev/null || true)"
if [ -n "$LATEST_TAG" ]; then
  if [ "$(version_cmp "$TAG" "$LATEST_TAG")" -le 0 ]; then
    die "$TAG is not newer than the current latest release $LATEST_TAG.
   Nothing installed would be offered it. Bump bundle/Info.plist."
  fi
  echo "    latest published is $LATEST_TAG -> $TAG"
else
  echo "    no published release yet; $TAG will be the first"
fi

# Notes. Default to the commit subjects since the last release, which is the
# whole changelog this repo keeps.
if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || die "no such notes file: $NOTES_FILE"
  NOTES="$(cat "$NOTES_FILE")"
elif [ -n "$NOTES_TEXT" ]; then
  NOTES="$NOTES_TEXT"
else
  RANGE=""
  [ -n "$LATEST_TAG" ] && git -C "$ROOT" rev-parse -q --verify "$LATEST_TAG^{commit}" >/dev/null \
    && RANGE="$LATEST_TAG..HEAD"
  NOTES="$(git -C "$ROOT" log ${RANGE:+"$RANGE"} --no-merges --format='- %s')"
fi
[ -n "${NOTES//[[:space:]]/}" ] || die "release notes are empty -- pass --notes= or --notes-file="

if [ "$DRY_RUN" = 0 ]; then
  for a in "${DMG_ARGS[@]+"${DMG_ARGS[@]}"}"; do
    [ "$a" = "--skip-notarize" ] && die "--skip-notarize cannot be published: macOS tells anyone
   who downloads an unnotarized DMG that it cannot be checked for malicious
   software. Use it with --dry-run to rehearse the build."
  done
fi

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

if [ "$REUSE_DMG" = 1 ]; then
  [ -f "$DMG" ] || die "--reuse-dmg but there is no $DMG"
  echo "==> reusing $DMG ($(du -h "$DMG" | cut -f1), built $(date -r "$DMG" '+%Y-%m-%d %H:%M'))"
else
  echo "==> build + notarize (scripts/make-dmg.sh)"
  "$ROOT/scripts/make-dmg.sh" "${DMG_ARGS[@]+"${DMG_ARGS[@]}"}"
fi
[ -f "$DMG" ] || die "make-dmg.sh did not produce $DMG"

# ---------------------------------------------------------------------------
# verify the artifact -- the same questions the app asks before it installs
# ---------------------------------------------------------------------------

echo "==> verify $(basename "$DMG")"

if [ "$DRY_RUN" = 0 ]; then
  xcrun stapler validate "$DMG" >/dev/null \
    || die "$DMG has no stapled notarization ticket. Publishing it would hand
   every downloader a Gatekeeper refusal. Rebuild without --skip-notarize."
  echo "    notarization ticket: stapled"
fi

MOUNT=""
cleanup() { [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; }
trap cleanup EXIT
MOUNT="$(hdiutil attach "$DMG" -nobrowse -readonly | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[ -n "$MOUNT" ] && [ -d "$MOUNT" ] || die "could not mount $DMG"

MOUNTED_APP="$MOUNT/$APP_NAME"
[ -d "$MOUNTED_APP" ] || die "the disk image does not contain $APP_NAME -- every install would refuse it"

DMG_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
[ "$DMG_VER" = "$VER" ] || die "the disk image contains $DMG_VER but the release would be tagged $TAG.
   The app checks exactly this and refuses the mismatch. Rebuild the DMG."

# Byte-for-byte the requirement in verify_bundle() in src/update.mm. Not a
# paraphrase of it: an install fails closed on this string.
REQ="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
codesign --verify --strict -R="$REQ" "$MOUNTED_APP" 2>/dev/null \
  || die "the app in the disk image does not satisfy the requirement every install checks:
     $REQ
   $(codesign --verify --strict -R="$REQ" "$MOUNTED_APP" 2>&1 | sed 's/^/   /')"

SIGN_INFO="$(codesign --display --verbose=4 "$MOUNTED_APP" 2>&1)"
grep -qE 'flags=[^ ]*runtime' <<<"$SIGN_INFO" || die "hardened runtime missing from the shipped app"
APP_ENTS="$(codesign -d --entitlements - --xml "$MOUNTED_APP" 2>/dev/null || true)"
grep -q 'com.apple.security.device.audio-input' <<<"$APP_ENTS" \
  || die "audio-input entitlement missing -- the shipped app would capture silence"

echo "    $APP_NAME $DMG_VER, signed by $TEAM_ID, hardened runtime, mic entitlement: ok"
hdiutil detach "$MOUNT" -quiet; MOUNT=""
trap - EXIT

DMG_SIZE="$(stat -f %z "$DMG")"

# ---------------------------------------------------------------------------
# publish
# ---------------------------------------------------------------------------

echo
echo "    tag:    $TAG at ${SHA:0:8} ($BRANCH)"
echo "    asset:  ${DMG##*/} ($(du -h "$DMG" | cut -f1))"
echo "    notes:"
sed 's/^/      /' <<<"$NOTES"
echo

if [ "$DRY_RUN" = 1 ]; then
  echo "==> dry run: everything above checks out, nothing was published"
  exit 0
fi

if [ "$ASSUME_YES" = 0 ]; then
  [ -t 0 ] || die "not a terminal and --yes was not given; refusing to publish unattended"
  printf 'Publish this to %s? Every install on <= %s is offered it. [y/N] ' "$SLUG" "${LATEST_TAG:-nothing}"
  read -r reply
  case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "aborted."; exit 1 ;; esac
fi

if [ "$REL_STATE" = draft ]; then
  echo "==> delete previous draft $TAG"
  gh release delete "$TAG" --repo "$SLUG" --yes --cleanup-tag
fi

NOTES_TMP="$(mktemp -t yap-release-notes)"
trap 'rm -f "$NOTES_TMP"' EXIT
printf '%s\n' "$NOTES" > "$NOTES_TMP"

# Draft first. /releases/latest skips drafts, so nothing in the field can see a
# release whose gigabyte is still in flight.
echo "==> create draft $TAG and upload ${DMG##*/} (this takes a while)"
gh release create "$TAG" "$DMG" \
   --repo "$SLUG" --target "$SHA" --draft \
   --title "Yap $VER" --notes-file "$NOTES_TMP"

# Confirm the bytes landed before making it visible. A truncated upload still
# produces an asset, and the app would download it and fail the signature check.
UPLOADED="$(gh release view "$TAG" --repo "$SLUG" --json assets \
            --jq '.assets[] | select(.name | endswith(".dmg")) | "\(.name) \(.size)"' | head -1)"
[ -n "$UPLOADED" ] || die "the draft $TAG has no .dmg asset after the upload"
UP_NAME="${UPLOADED% *}"; UP_SIZE="${UPLOADED##* }"
[ "$UP_SIZE" = "$DMG_SIZE" ] || die "uploaded $UP_NAME is $UP_SIZE bytes, local DMG is $DMG_SIZE.
   The draft is left in place; delete it and re-run:
     gh release delete $TAG --repo $SLUG --yes --cleanup-tag"
echo "    uploaded $UP_NAME ($UP_SIZE bytes, matches local)"

echo "==> publish $TAG"
gh release edit "$TAG" --repo "$SLUG" --draft=false --latest

# ---------------------------------------------------------------------------
# verify live -- against the one endpoint the app actually reads
# ---------------------------------------------------------------------------

echo "==> verify /releases/latest"
LIVE="$(gh api "repos/$SLUG/releases/latest" \
        --jq '"\(.tag_name)\t\([.assets[] | select(.name | endswith(".dmg")) | .browser_download_url] | first // "")"')"
LIVE_TAG="${LIVE%%$'\t'*}"; LIVE_URL="${LIVE##*$'\t'}"
[ "$LIVE_TAG" = "$TAG" ] || die "published, but /releases/latest still reports $LIVE_TAG.
   Check https://github.com/$SLUG/releases"
[ -n "$LIVE_URL" ] || die "published, but /releases/latest has no .dmg asset"
case "$LIVE_URL" in
  https://github.com/*|https://*.github.com/*|https://*.githubusercontent.com/*) ;;
  *) die "the asset URL is $LIVE_URL, which the app will refuse as not GitHub-over-TLS" ;;
esac

echo
echo "==> published: https://github.com/$SLUG/releases/tag/$TAG"
echo "    /releases/latest now reports $LIVE_TAG"
echo "    Installed copies check once a day, so most will see it within 24h;"
echo "    Check for Updates in the menu forces it now."
