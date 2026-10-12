#!/bin/zsh
# release.sh: build, Developer ID-sign, notarize and staple LLM Switcher, then package a DMG.
#   scripts/release.sh            -> dist/LLM-Switcher-<version>.dmg (signed, notarized, stapled)
#   scripts/release.sh --install  -> also copies the app to /Applications
# Notarizing needs an App Store Connect API key. Set ASC_KEY_ID, ASC_ISSUER_ID and (optionally)
# ASC_KEY_PATH, or put them in ~/.config/llm-switcher/release.env (outside the repo). The values
# are never printed. Building for yourself needs none of this: open the Xcode project and Run.
set -e
cd "${0:A:h}/.."
ROOT=$PWD
ENV_FILE=~/.config/llm-switcher/release.env
[[ -f $ENV_FILE ]] && source $ENV_FILE
KEY_ID=${ASC_KEY_ID:-}
ISSUER=${ASC_ISSUER_ID:-}
KEY_PATH=${ASC_KEY_PATH:-~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}
# Your Apple team: DEVELOPMENT_TEAM in Config/Local.xcconfig (git-ignored), or the environment.
TEAM_ID=${DEVELOPMENT_TEAM:-$(sed -nE 's/^DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' Config/Local.xcconfig 2>/dev/null)}
[[ -n $TEAM_ID ]] || { echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig (see Config/Signing.xcconfig)"; exit 1; }
[[ -n $KEY_ID && -n $ISSUER && -f $KEY_PATH ]] || { echo "Set ASC_KEY_ID / ASC_ISSUER_ID (see the top of this script)"; exit 1; }

VERSION=$(grep -E 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
ARCHIVE=build/ClaudeLocal.xcarchive
EXPORT=build/export
DIST=dist
rm -rf $ARCHIVE $EXPORT; mkdir -p $DIST

echo "==> Generating project"
xcodegen generate >/dev/null

echo "==> Archiving $VERSION"
xcodebuild -project ClaudeLocal.xcodeproj -scheme ClaudeLocal -configuration Release \
  -archivePath $ARCHIVE -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d $ARCHIVE ]] || { echo "Archive failed"; exit 1; }

echo "==> Exporting with Developer ID"
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $EXPORT -exportOptionsPlist build/ExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
APP="$EXPORT/LLM Switcher.app"
[[ -d $APP ]] || { echo "Export failed"; exit 1; }
codesign --verify --deep --strict "$APP" && echo "    signature OK"

echo "==> Notarizing the app"
ZIP=build/ClaudeLocal-notarize.zip
ditto -c -k --keepParent "$APP" $ZIP
xcrun notarytool submit $ZIP --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait | grep -E "status:|id:" | tail -2
xcrun stapler staple "$APP" | tail -1

echo "==> Building DMG"
DMG="$DIST/LLM-Switcher-$VERSION.dmg"
STAGE=build/dmg; rm -rf $STAGE; mkdir -p $STAGE
cp -R "$APP" $STAGE/
ln -s /Applications $STAGE/Applications
rm -f "$DMG"
hdiutil create -volname "LLM Switcher" -srcfolder $STAGE -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG" 2>/dev/null || true
xcrun notarytool submit "$DMG" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait | grep -E "status:" | tail -1
xcrun stapler staple "$DMG" | tail -1
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | tail -1
echo "==> Done: $ROOT/$DMG"

if [[ "$1" == "--install" ]]; then
  pkill -x "LLM Switcher" 2>/dev/null || true
  # An older copy goes to the Trash (recoverable), never deleted outright.
  PREV=~/.Trash/llm-switcher-previous-$(date +%Y%m%d-%H%M%S)   # exact name: macOS won't let us list the Trash
  pkill -x "Claude Local" 2>/dev/null || true
  if [[ -d "/Applications/Claude Local.app" ]]; then          # the same app under its old name
    mkdir -p "$PREV"
    mv "/Applications/Claude Local.app" "$PREV/"
  fi
  if [[ -d "/Applications/LLM Switcher.app" ]]; then
    mkdir -p "$PREV"
    mv "/Applications/LLM Switcher.app" "$PREV/"
  fi
  cp -R "$APP" /Applications/
  echo "==> Installed /Applications/LLM Switcher.app"
  # Keep an installed Claude Code review hook in step with the repo (never installs it fresh).
  HOOK=~/.claude/hooks/llm-switcher-review.py
  if [[ -f $HOOK ]]; then
    cp scripts/llm-review-hook.py "$HOOK" && chmod +x "$HOOK" && echo "==> Updated the Claude Code review hook"
  fi
  # The lsw terminal command.
  BIN=/opt/homebrew/bin; [[ -d $BIN && -w $BIN ]] || BIN=/usr/local/bin
  cp scripts/lsw "$BIN/lsw" && chmod +x "$BIN/lsw" && echo "==> Installed $BIN/lsw"
  open -a "/Applications/LLM Switcher.app"
fi
