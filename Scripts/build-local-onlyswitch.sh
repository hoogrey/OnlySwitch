#!/bin/zsh

set -euo pipefail

repo=${0:A:h:h}
derived_data=${DERIVED_DATA:-$repo/build/DerivedData}
output=${1:-$repo/build/local/Only Switch Local.app}

if (( $# > 1 )) || [[ ${1:-} == --help || ${1:-} == -h ]]; then
    print "Usage: $0 [output.app]"
    exit $(( $# > 1 ? 64 : 0 ))
fi

if [[ -e "$output" || -L "$output" ]]; then
    print -u2 "Output already exists: $output"
    exit 1
fi

xcodebuild \
    -project "$repo/OnlySwitch.xcodeproj" \
    -scheme OnlySwitch \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    build

exec python3 "$repo/Scripts/package-local-onlyswitch.py" \
    --source "$derived_data/Build/Products/Release/OnlySwitch.app" \
    --output "$output"
