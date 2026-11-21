# Only Switch Local

On an Apple silicon Mac, use macOS 14 or later, the Xcode version required by the project, and Python 3.9 or later. A paid Apple Developer account and a signing certificate are unnecessary for this local build.

From the repository root, run the following command.

```sh
Scripts/build-local-onlyswitch.sh
```

The script builds Release and ad-hoc signs a copy at `build/local/Only Switch Local.app`. The original build product stays in `build/DerivedData`. The first build downloads dependencies. The script skips macro validation for the dependencies in this checkout. Run it against a checkout and dependencies you trust.

Move the signed app to Applications with Finder and open **Only Switch Local**. It can be installed alongside the official app. It uses the separate bundle identifier `local.OnlySwitch`, URL scheme `onlyswitch-local`, settings, Keychain services, and app data. The widget and features requiring the privileged helper are unavailable. Updates come from rebuilding the source.

Its database is `~/Library/Application Support/OnlySwitchLocal/onlyswitch.sqlite`. Official app-group databases are never discovered or moved by the local app. Its language setting, screenshot index, Aphrodite library, and app-owned Keychain services are independent as well. Bluetooth device discovery waits until CoreBluetooth reports that Bluetooth is ready, so the scheduler catalog can initialize without a synchronous paired-device lookup during startup.

For another build, move the previous output aside or pass a new path such as `Scripts/build-local-onlyswitch.sh 'build/local/rebuilt/Only Switch Local.app'`. Quit the installed local app before replacing it in Finder. macOS may ask you to grant permissions again after an ad-hoc signed rebuild.

To package an existing Release product built from this checkout, run the following command.

```sh
python3 Scripts/package-local-onlyswitch.py \
  --source build/DerivedData/Build/Products/Release/OnlySwitch.app \
  --output 'build/local/Only Switch Local.app'
```

To transfer supported preferences, use **Settings > General > Backup > Export Settings** in the original app and **Import Settings** in Only Switch Local. Export and import individual items in features that provide their own backup commands. Sign in again to restore access to external accounts.
