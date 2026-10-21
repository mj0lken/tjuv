#!/usr/bin/env bash
# Cuts a release in one go: runs the tests, builds and zips the app, publishes the GitHub release,
# checks the uploaded zip, and updates the Homebrew cask.
#
#   scripts/release.sh 1.0.0                     # release main as it is on GitHub
#   scripts/release.sh 1.0.0 --dry-run           # everything local (tests, build, zip, notes, cask), nothing published
#   scripts/release.sh 1.0.0 --notes-file x.md   # your own release notes instead of the generated ones
#
# Expects the tap checked out next to this repo (../homebrew-tap), or TAP_DIR set.
set -euo pipefail

VERSION="${1:-}"
[[ $# -gt 0 ]] && shift
DRY_RUN=false
NOTES_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --notes-file)
      NOTES_FILE="$(cd "$(dirname "${2:?--notes-file needs a file}")" && pwd)/$(basename "$2")"
      [[ -f "$NOTES_FILE" ]] || { echo "release: no notes file at $2" >&2; exit 2; }
      shift ;;
    *) echo "release: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."

REPO="mj0lken/tjuv"
TAP_DIR="${TAP_DIR:-$(cd .. && pwd)/homebrew-tap}"
CASK="$TAP_DIR/Casks/tjuv.rb"

fail() { echo "release: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
require() { if $DRY_RUN; then echo "(dry run) warning: $1"; else fail "$1"; fi }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: scripts/release.sh X.Y.Z [--dry-run] [--notes-file FILE]"
TAG="v$VERSION"
ZIP="build/tjuv-$VERSION-arm64.zip"
NOTES_PATH="build/release-notes-$VERSION.md"
PREPARED_CASK="build/tjuv-$VERSION.cask.rb"
WORK=$(mktemp -d)

DONE=""
cleanup() {
  local status=$?
  if [[ $status -ne 0 && -n "$DONE" ]]; then
    echo >&2
    echo "release: stopped after: ${DONE# }" >&2
    case "$DONE" in
      *tap-pushed*) ;;
      *published*) echo "  The release is public but the cask isn't updated. Finish with:" >&2
                   echo "    cp $PREPARED_CASK $CASK && git -C $TAP_DIR commit -am 'tjuv $VERSION' && git -C $TAP_DIR push" >&2 ;;
      *drafted*)   echo "  A draft release exists (not public, no tag yet). Delete it and run again:" >&2
                   echo "    gh release delete $TAG --repo $REPO --yes" >&2 ;;
    esac
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

step "Checking the repository and tools"
[[ "$(git branch --show-current)" == "main" ]] || require "not on main"
[[ -z "$(git status --porcelain)" ]] || require "uncommitted changes; the release builds what's committed"
git fetch -q origin --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || require "HEAD isn't origin/main; pull first"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "$TAG already exists"; fi
PREVIOUS=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
if [[ -n "$PREVIOUS" ]]; then
  NEWEST=$(printf '%s\n%s\n' "${PREVIOUS#v}" "$VERSION" | sort -V | tail -1)
  [[ "$NEWEST" == "$VERSION" && "${PREVIOUS#v}" != "$VERSION" ]] || fail "$VERSION isn't newer than $PREVIOUS"
fi
if gh auth status >/dev/null 2>&1; then
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then fail "a release (maybe a draft) called $TAG already exists"; fi
else
  require "gh isn't signed in (gh auth login)"
fi
[[ -f "$CASK" ]] || fail "no cask at $CASK; set TAP_DIR to the homebrew-tap checkout"
[[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] || require "the tap has uncommitted changes"
$DRY_RUN || git -C "$TAP_DIR" pull -q --ff-only
TARGET=$(git rev-parse HEAD)
BUILD_NUMBER=$(git rev-list --count HEAD)

step "Testing"
swift test 2>&1 | tail -3

step "Building $VERSION ($BUILD_NUMBER) and zipping"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ./scripts/build-app.sh
codesign --verify --strict build/Tjuv.app
[[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Tjuv.app/Contents/Info.plist)" == "$VERSION" ]] \
  || fail "the built app doesn't say $VERSION"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Tjuv.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$ZIP  $SHA"

step "Preparing the Homebrew cask"
mkdir -p "$WORK/Casks"
UPDATED="$WORK/Casks/tjuv.rb"
sed -E -e "s/^  version \".*\"$/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"$/  sha256 \"$SHA\"/" "$CASK" > "$UPDATED"
grep -qx "  version \"$VERSION\"" "$UPDATED" && grep -qx "  sha256 \"$SHA\"" "$UPDATED" \
  || fail "couldn't set the version and sha256 in $CASK; has its format changed?"
diff -u "$CASK" "$UPDATED" || true
brew style "$UPDATED"
cp "$UPDATED" "$PREPARED_CASK"

step "Writing release notes"
if [[ -n "$NOTES_FILE" ]]; then
  cp "$NOTES_FILE" "$WORK/notes.md" && mv "$WORK/notes.md" "$NOTES_PATH"
else
  changes() {
    git log --no-merges --format='%s' "${PREVIOUS:+$PREVIOUS..}HEAD" \
      -- Sources Resources Package.swift ':(exclude)Sources/Tjuv/Debug' \
      | sed -nE "s/^$1(\([^)]*\))?: (.*)$/- \2/p"
  }
  NEW=$(changes feat)
  FIXED=$(changes fix)
  {
    echo "## What's new"
    echo "${NEW:-- Initial public release of Tjuv}"
    if [[ -n "$FIXED" ]]; then printf '\n## Fixes\n%s\n' "$FIXED"; fi
    cat <<EOF

**Requirements:** Apple Silicon Mac, macOS 15 or later.

**Install or update:** \`brew install --cask mj0lken/tap/tjuv\` (or \`brew upgrade --cask tjuv\`), or unzip, drag **Tjuv.app** to Applications and open it. The app isn't signed with a paid Apple Developer ID yet, so the first launch of a new download is blocked: click **Done**, then go to **System Settings › Privacy & Security** and click **Open Anyway**.

SHA-256 of \`$(basename "$ZIP")\`: \`$SHA\`
EOF
  } > "$NOTES_PATH"
fi
cat "$NOTES_PATH"

if $DRY_RUN; then
  step "Done (dry run)"
  echo "Nothing was tagged, published or pushed."
  exit 0
fi

step "Publishing $TAG from ${TARGET:0:7}"
gh release create "$TAG" "$ZIP" --repo "$REPO" --draft --target "$TARGET" \
  --title "Tjuv $VERSION" --notes-file "$NOTES_PATH"
DONE="$DONE drafted"

step "Checking the uploaded zip"
ASSET_URL=$(gh api "repos/$REPO/releases?per_page=20" \
  --jq ".[] | select(.tag_name == \"$TAG\") | .assets[] | select(.name == \"$(basename "$ZIP")\") | .url")
[[ -n "$ASSET_URL" ]] || fail "can't find the uploaded zip on the draft release"
gh api -H "Accept: application/octet-stream" "$ASSET_URL" > "$WORK/uploaded.zip"
[[ "$(shasum -a 256 "$WORK/uploaded.zip" | cut -d' ' -f1)" == "$SHA" ]] \
  || fail "the uploaded zip doesn't match the local one"
echo "matches $SHA"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
DONE="$DONE published"
git fetch -q origin --tags

step "Updating the Homebrew cask"
cp "$UPDATED" "$CASK"
git -C "$TAP_DIR" commit -q -m "tjuv $VERSION" -- Casks/tjuv.rb
git -C "$TAP_DIR" push -q
DONE="$DONE tap-pushed"

step "Done"
echo "Release:  https://github.com/$REPO/releases/tag/$TAG"
echo "Homebrew: brew upgrade --cask tjuv (after brew update)"
