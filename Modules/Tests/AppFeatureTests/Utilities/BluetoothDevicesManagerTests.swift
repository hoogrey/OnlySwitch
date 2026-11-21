import CoreBluetooth
import Testing
@testable import AppFeature

struct BluetoothDevicesManagerTests {
    @Test(arguments: [
        CBManagerState.unknown, .resetting, .unsupported, .unauthorized, .poweredOff, .poweredOn
    ])
    func pairedDeviceLoadingRequiresPoweredOnBluetooth(state: CBManagerState) {
        var loads = 0
        let devices = BluetoothDevicesManager.pairedDevices(state: state) {
            loads += 1
            return ["device"]
        }

        let ready = state == .poweredOn
        #expect(loads == (ready ? 1 : 0))
        #expect(devices == (ready ? ["device"] : []))
    }
}
