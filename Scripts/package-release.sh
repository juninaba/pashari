#!/bin/bash
# Builds Pashari for release and packs it into build/release as
# Pashari-<version>.dmg and Pashari-<version>.zip. The release workflow
# (.github/workflows/release.yml) runs this script; it also works locally.
#
# The app is signed ad hoc, which needs no Apple Developer Program
# membership. Apple does not notarize such apps, so macOS asks users to
# confirm the first time they open one (see "Installing" in the README).
set -euo pipefail

cd "$(dirname "$0")/.."

out=build/release
rm -rf "$out"
mkdir -p "$out"

xcodegen generate

# Settings given on the command line win over Config/Local.xcconfig, so a
# release never carries a developer's own certificate or team ID.
xcodebuild archive \
    -scheme Pashari \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build/DerivedData-release \
    -archivePath "$out/Pashari.xcarchive" \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=

app="$out/Pashari.xcarchive/Products/Applications/Pashari.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")

# --norsrc, here and below, leaves out the build machine's extended
# attributes, such as the com.apple.provenance that macOS can add to every
# file. A zip would hold them as ._ files inside the app, and unzip tools
# other than macOS's own leave those in place, which breaks the signature.
ditto -c -k --norsrc --keepParent "$app" "$out/Pashari-$version.zip"

# The disk image shows the app next to a link to Applications, to drag it to.
dmg_root="$out/dmg"
mkdir "$dmg_root"
ditto --norsrc "$app" "$dmg_root/Pashari.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -volname Pashari -srcfolder "$dmg_root" -format UDZO "$out/Pashari-$version.dmg"
rm -rf "$dmg_root"

echo "Packed $out/Pashari-$version.dmg and $out/Pashari-$version.zip"
