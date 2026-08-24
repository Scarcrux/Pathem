import AppKit
import PathemEngine

// USB device watching: poll for attached phones (iOS via the native usbmux client, Android via adb
// when installed) and feed the sidebar's Devices section. Extracted from BrowserViewController to
// shrink the god-object (5.1). The deviceTimer / deviceNameCache state stays on the controller
// (stored properties can't live in an extension); only the polling behavior moved here.
extension BrowserViewController {
    /// Poll for USB-attached phones. iOS uses our native usbmux client (always available);
    /// Android uses adb when installed. The sidebar's Devices section updates on change.
    func startDeviceWatch() {
        refreshDevices()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    /// Stop the repeating device-poll timer (from teardown when the window closes).
    func stopDeviceTimer() {
        deviceTimer?.invalidate()
        deviceTimer = nil
    }

    private func refreshDevices() {
        Task { @MainActor in
            var devices = await DeviceDiscovery.androidDevices()
            for udid in DeviceDiscovery.iosUDIDs() {
                let name: String
                if let cached = self.deviceNameCache[udid] {
                    name = cached
                } else if let resolved = await AFCProvider.friendlyName(udid: udid) {
                    self.deviceNameCache[udid] = resolved  // cache only a real name
                    name = resolved
                } else {
                    name = L("bvc.iphoneFallback", "iPhone")  // not cached, so a later poll retries
                }
                devices.append(RemoteConnection(name: name, proto: .afc, host: udid, path: "/"))
            }
            self.sidebar.setDevices(devices)
        }
    }
}
