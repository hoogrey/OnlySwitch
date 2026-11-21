import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


script = Path(__file__).with_name("package-local-onlyswitch.py")
spec = importlib.util.spec_from_file_location("package_local_onlyswitch", script)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PrepareBundleTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.source = Path(temp.name) / "OnlySwitch.app"
        self.destination = Path(temp.name) / "Only Switch Local.app"
        self.contents = self.source / "Contents"
        self.contents.mkdir(parents=True)
        info = {
            "CFBundleIdentifier": "com.jacklandrin.OnlySwitch",
            "CFBundleExecutable": "OnlySwitch",
            "CFBundleName": "OnlySwitch",
            "CFBundleDisplayName": "Only Switch",
            "AppIdentifierPrefix": "TESTTEAM.",
            "CFBundleURLTypes": [{
                "CFBundleURLName": "jacklandrin.OnlySwitch",
                "CFBundleURLSchemes": ["onlyswitch"],
            }],
            "SUFeedURL": "https://example.invalid/appcast.xml",
            "SUEnableAutomaticChecks": False,
            "SUPublicEDKey": "fixture",
        }
        self.localized = Path("Resources/en.lproj/InfoPlist.strings")
        self.framework = Path("Frameworks/Sparkle.framework/Versions/B")
        self.removed = [
            Path("PlugIns/OnlyWidgetExtension.appex/Contents/Info.plist"),
            Path("MacOS/OnlySwitchPrivilegedHelper"),
            Path("Library/LaunchDaemons/com.jacklandrin.OnlySwitch.PrivilegedHelper.plist"),
            Path("Library/LoginItems/LaunchAtLoginHelper.app/Contents/MacOS/LaunchAtLoginHelper"),
        ]
        files = {
            Path("Info.plist"): plistlib.dumps(info),
            Path("MacOS/OnlySwitch"): b"fixture executable",
            self.framework / "Sparkle": b"framework",
            self.framework / "Updater.app/Contents/MacOS/Updater": b"nested updater",
            self.localized: plistlib.dumps({
                "CFBundleDisplayName": "Official localized name",
                "CFBundleName": "Official localized bundle name",
                "NSScreenCaptureUsageDescription": "Capture permission",
            }, fmt=plistlib.FMT_BINARY),
        }
        files.update({path: b"official component" for path in self.removed})
        for path, data in files.items():
            target = self.contents / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.original_files = files

    def test_prepares_independent_copy(self):
        package.prepare_bundle(self.source, self.destination)
        contents = self.destination / "Contents"
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "local.OnlySwitch")
        self.assertIs(info["OnlySwitchLocalMode"], True)
        self.assertEqual(info["CFBundleName"], "OnlySwitchLocal")
        self.assertEqual(info["CFBundleDisplayName"], "Only Switch Local")
        self.assertFalse(info.get("AppIdentifierPrefix"))
        schemes = [scheme for entry in info["CFBundleURLTypes"] for scheme in entry["CFBundleURLSchemes"]]
        self.assertEqual(schemes, ["onlyswitch-local"])
        self.assertFalse(any(key.startswith("SU") for key in info))

        localized_xml = subprocess.check_output(
            ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(contents / self.localized)]
        )
        localized = plistlib.loads(localized_xml)
        for key in ("CFBundleName", "CFBundleDisplayName"):
            self.assertEqual(localized.get(key, info[key]), info[key])
        self.assertEqual(localized["NSScreenCaptureUsageDescription"], "Capture permission")
        self.assertFalse((contents / "PlugIns").exists())
        for path in self.removed:
            self.assertFalse((contents / path).exists(), path)
        for path in self.original_files:
            if path == Path("MacOS/OnlySwitch") or self.framework in path.parents:
                self.assertEqual((contents / path).read_bytes(), self.original_files[path])

        source_files = {
            path.relative_to(self.contents): path.read_bytes()
            for path in self.contents.rglob("*") if path.is_file()
        }
        self.assertEqual(source_files, self.original_files)

    def test_refuses_to_overwrite_existing_destination(self):
        self.destination.mkdir()
        sentinel = self.destination / "user-edits"
        sentinel.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            package.prepare_bundle(self.source, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"existing")


if __name__ == "__main__":
    unittest.main()
