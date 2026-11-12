#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'This script requires macOS with Xcode and the iOS SDK.' >&2
  exit 1
fi
python3 "$project_root/scripts/assemble_runtime.py"
macpkg_flags=""
if bash "$project_root/scripts/build_mac_pkg_bridge.sh"; then
  macpkg_flags="$(cat "$project_root/build/macpkg/link-flags.txt")"
elif [ "${IPADN_REQUIRE_MACPKG:-0}" = "1" ]; then
  echo 'Mac PKG bridge build failed.' >&2
  exit 1
else
  echo 'warning: Mac PKG bridge not built; Mac App Store PKG downloads will be unavailable.' >&2
fi
native_flags=""
if bash "$project_root/scripts/build_native_install.sh"; then
  native_flags="$(cat "$project_root/build/native/link-flags.txt")"
elif [ "${IPADN_REQUIRE_NATIVE:-0}" = "1" ]; then
  echo 'Native installation library build failed.' >&2
  exit 1
else
  echo 'warning: native installation library not built; native installation will be unavailable.' >&2
fi
xcodebuild -resolvePackageDependencies -project "$project_root/iPadn.xcodeproj" -scheme iPadn
xcodebuild -project "$project_root/iPadn.xcodeproj" -scheme iPadn -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$project_root/build/DerivedData" CODE_SIGNING_ALLOWED=NO \
  IPADN_MACPKG_LDFLAGS="$macpkg_flags" IPADN_NATIVE_LDFLAGS="$native_flags" build
package_root="$project_root/build/Export"
mkdir -p "$package_root/Payload"
if [ -d "$package_root/Payload/iPadn.app" ]; then
  rm -r "$package_root/Payload/iPadn.app"
fi
cp -R "$project_root/build/DerivedData/Build/Products/Release-iphoneos/iPadn.app" "$package_root/Payload/"
if [ -n "$macpkg_flags" ]; then
  cp "$project_root/build/macpkg/Unicorn-GPL-2.0.txt" "$project_root/build/macpkg/ipatool-MIT.txt" \
    "$package_root/Payload/iPadn.app/"
fi
if [ -n "$native_flags" ]; then
  cp "$project_root/build/native/idevice-MIT.txt" "$package_root/Payload/iPadn.app/"
fi
ditto -c -k --keepParent "$package_root/Payload" "$project_root/build/iPadn-unsigned.ipa"
echo "Created $project_root/build/iPadn-unsigned.ipa (requires your signing tool before installation)."
