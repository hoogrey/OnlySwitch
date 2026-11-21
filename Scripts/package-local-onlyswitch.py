#!/usr/bin/env python3
"""Prepare and ad-hoc sign a standalone Only Switch app on macOS."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


APP_NAME = "Only Switch Local.app"
LOCAL_NAMES = {
    "CFBundleName": "OnlySwitchLocal",
    "CFBundleDisplayName": "Only Switch Local",
}
LOCAL_ID = "local.OnlySwitch"
LOCAL_SCHEME = "onlyswitch-local"
OFFICIAL_METADATA_KEYS = {
    "AppIdentifierPrefix",
    "TeamIdentifierPrefix",
    "TeamIdentifier",
    "ApplicationIdentifier",
    "application-identifier",
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "com.apple.security.application-groups",
    "keychain-access-groups",
    "ProvisioningProfile",
    "ProvisioningProfileUUID",
    "SMPrivilegedExecutables",
}
OFFICIAL_COMPONENTS = (
    "PlugIns",
    "MacOS/OnlySwitchPrivilegedHelper",
    "Library/LaunchDaemons",
    "Library/LoginItems/LaunchAtLoginHelper.app",
    "embedded.provisionprofile",
    "embedded.mobileprovision",
)
LOCAL_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": False,
    "com.apple.security.automation.apple-events": True,
    "com.apple.security.device.bluetooth": True,
    "com.apple.security.network.client": True,
    "com.apple.security.personal-information.photos-library": True,
}
DOWNLOADER_ENTITLEMENTS = {
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
}


def prepare_bundle(source: Path, destination: Path) -> None:
    """Create an unsigned staging copy with local metadata and resources."""
    source = source.resolve(strict=True)
    if destination.resolve().is_relative_to(source):
        raise ValueError("Output must be outside the source bundle.")
    destination.mkdir()
    try:
        subprocess.run(["/usr/bin/ditto", source, destination], check=True)
        copy_root = destination.resolve()
        for item in destination.rglob("*"):
            if item.is_symlink() and not item.resolve().is_relative_to(copy_root):
                raise ValueError(f"Bundle symlink points outside the copy: {item}")

        contents = destination / "Contents"
        manifest = contents / "Info.plist"
        with manifest.open("rb") as file:
            info = plistlib.load(file)
        for key in list(info):
            if key in OFFICIAL_METADATA_KEYS or key.startswith("SU"):
                del info[key]
        info.update(LOCAL_NAMES)
        info["CFBundleIdentifier"] = LOCAL_ID
        info["CFBundleURLTypes"] = [{
            "CFBundleTypeRole": "Editor",
            "CFBundleURLName": LOCAL_ID,
            "CFBundleURLSchemes": [LOCAL_SCHEME],
        }]
        info["OnlySwitchLocalMode"] = True
        manifest.write_bytes(plistlib.dumps(info))

        for strings in (contents / "Resources").glob("*.lproj/InfoPlist.strings"):
            xml = subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", strings])
            localized = plistlib.loads(xml)
            localized.update(LOCAL_NAMES)
            strings.write_bytes(plistlib.dumps(localized, fmt=plistlib.FMT_BINARY))

        for component in OFFICIAL_COMPONENTS:
            path = contents / component
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
    except BaseException:
        shutil.rmtree(destination)
        raise


def sign(path: Path, entitlements: Path | None = None) -> None:
    command = ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none"]
    if entitlements is not None:
        command.extend(["--entitlements", entitlements])
    subprocess.run([*command, path], check=True)


def sign_bundle(app: Path, staging: Path) -> None:
    # Match the nested code layout in sign-sparkle-for-distribution.sh.
    framework = app / "Contents/Frameworks/Sparkle.framework"
    version = framework / "Versions/Current"
    downloader = version / "XPCServices/Downloader.xpc"
    existing = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", downloader],
        capture_output=True,
    )
    downloader_entitlements = None
    if existing.returncode == 0 and existing.stdout:
        entitlements = plistlib.loads(existing.stdout)
        retained = {key: entitlements[key] for key in DOWNLOADER_ENTITLEMENTS if key in entitlements}
        if retained:
            downloader_entitlements = staging / "downloader-entitlements.plist"
            downloader_entitlements.write_bytes(plistlib.dumps(retained))

    sign(version / "XPCServices/Installer.xpc")
    sign(downloader, downloader_entitlements)
    sign(version / "Autoupdate")
    sign(version / "Updater.app")
    sign(framework)

    app_entitlements = staging / "local-entitlements.plist"
    app_entitlements.write_bytes(plistlib.dumps(LOCAL_ENTITLEMENTS))
    sign(app, app_entitlements)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)


def publish_bundle(source: Path, destination: Path) -> None:
    # macOS RENAME_EXCL makes publishing atomic even when another process
    # creates an empty destination directory after the initial check.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    rename_exclusive = 0x00000004
    if rename(os.fsencode(source), os.fsencode(destination), rename_exclusive) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="OnlySwitch.app built from this checkout")
    parser.add_argument("--output", required=True, type=Path, help="Path for the new .app bundle")
    args = parser.parse_args()
    try:
        source = args.source.resolve(strict=True)
        output = args.output.absolute()
        if output.exists() or output.is_symlink():
            raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), output)
        if output.resolve().is_relative_to(source):
            raise ValueError("Output must be outside the source bundle.")
        if output.suffix != ".app":
            raise ValueError("Output must use the .app extension.")
        output.parent.mkdir(parents=True, exist_ok=True)

        # Stage beside the destination to keep the verification and publish on
        # the same volume. The build wrapper defaults to build/local/.
        with tempfile.TemporaryDirectory(prefix=".onlyswitch-local-", dir=output.parent) as directory:
            staging = Path(directory)
            app = staging / APP_NAME
            prepare_bundle(source, app)
            sign_bundle(app, staging)
            publish_bundle(app, output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")
    print(output)


if __name__ == "__main__":
    main()
