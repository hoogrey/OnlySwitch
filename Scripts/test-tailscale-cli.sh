#!/bin/zsh
# Run the dependency-free Tailscale core tests with macOS Command Line Tools.
set -euo pipefail
repo=${0:A:h:h}
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/onlyswitch-tailscale-tests.XXXXXXXX")
trap 'rm -r -- "$package_dir"' EXIT

mkdir -p "$package_dir/Sources/Tailscale" "$package_dir/Tests/TailscaleTests"
cp "$repo/Modules/Sources/Tailscale/"Tailscale{Models,CLI,Coordinator,CommandRunner}.swift \
  "$package_dir/Sources/Tailscale/"
cp "$repo/Modules/Tests/TailscaleTests/"Tailscale{TestFixtures,CLITests,CoordinatorTests,CommandRunnerTests}.swift \
  "$package_dir/Tests/TailscaleTests/"

cat > "$package_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TailscaleCoreTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Tailscale"),
        .testTarget(name: "TailscaleTests", dependencies: ["Tailscale"])
    ]
)
SWIFT

print 'Running the Tailscale core suites with fixtures. TCA and UI tests are outside this package.'
swiftc_path=$(xcrun --find swiftc)
testing_macros="${swiftc_path:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
swift_flags=()
if [[ -f "$testing_macros" ]]; then
  swift_flags=(-Xswiftc -load-plugin-library -Xswiftc "$testing_macros")
fi
swift test --disable-xctest --package-path "$package_dir" "${swift_flags[@]}" "$@"
