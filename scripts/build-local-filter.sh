#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
build_dir=${TMPDIR:-/tmp}/midog-local-filter-build
app_path=$build_dir/Build/Products/Debug/midog.app
filter_path=$app_path/Contents/Library/SystemExtensions/com.xx.midog.filter.systemextension

xcodebuild -quiet -project "$project_root/midog.xcodeproj" -scheme midog \
    -configuration Debug -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO build
codesign --force --sign - --entitlements "$project_root/midogFilter/midogFilter-debug.entitlements" "$filter_path"
codesign --force --sign - --entitlements "$project_root/midog/midog-debug.entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"
print -- "$app_path"
