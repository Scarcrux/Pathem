import AppKit
import PathemEngine

/// Polls for USB-attached phones (iOS via the native usbmux client, Android via adb when installed)
/// and reports the current device list. Owns its own poll timer and friendly-name cache, so that
/// state lives here instead of on BrowserViewController (5.6: move state off the god-object, not just
/// methods). The host wires `onDevices` to feed the sidebar's Devices section.
@MainActor
final class DeviceWatcher {
    private var timer: Timer?
    private var nameCache: [String: String] = [:]  // iOS udid -> friendly DeviceName
    /// Called on the main actor whenever the attached-device list is (re)computed.
    var onDevices: (([RemoteConnection]) -> Void)?

    /// Begin polling (every 4s) and report once immediately.
    #if DEBUG
    private(set) static var debugTransientStarts = 0
    private(set) static var debugTransientSkips = 0
    #endif

    func start() {
        #if DEBUG
        // The transient surface harness owns UI fixtures only. In particular,
        // constructing a browser must not start LAN or paired-device discovery.
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_TEST"] != nil {
            Self.debugTransientSkips += 1
            return
        }
        Self.debugTransientStarts += 1
        #endif
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }  // the timer fires on the main run loop
        }
    }

    /// Stop the repeating poll (from teardown when the window closes).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        Task { @MainActor in
            var devices = await DeviceDiscovery.androidDevices()
            for udid in DeviceDiscovery.iosUDIDs() {
                let name: String
                if let cached = self.nameCache[udid] {
                    name = cached
                } else if let resolved = await AFCProvider.friendlyName(udid: udid) {
                    self.nameCache[udid] = resolved  // cache only a real name
                    name = resolved
                } else {
                    name = L("bvc.iphoneFallback", "iPhone")  // not cached, so a later poll retries
                }
                devices.append(RemoteConnection(name: name, proto: .afc, host: udid, path: "/"))
            }
            self.onDevices?(devices)
        }
    }
}
