#!/bin/sh
set -e
cd "$(dirname "$0")"
if [ ! -f Vendor/minimuxer/Package.swift ]; then
  git clone --depth 1 --branch develop https://github.com/SideStore/minimuxer.git Vendor/minimuxer
fi
xcodegen generate
xcodebuild -project FixableScanner.xcodeproj -scheme FixableScanner -destination "generic/platform=iOS" -archivePath build/Fixable.xcarchive archive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
APP=$(find build/Fixable.xcarchive/Products -name "*.app" -type d | head -1)
test -n "$APP"
rm -rf build/Payload
mkdir -p build/Payload
cp -R "$APP" build/Payload/
rm -f build/Fixable.ipa
(cd build && zip -r -y Fixable.ipa Payload)
echo "build/Fixable.ipa"
