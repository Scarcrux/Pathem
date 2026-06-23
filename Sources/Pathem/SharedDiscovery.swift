import Foundation

/// Discovers SMB file-sharing computers on the local network via Bonjour
/// (`_smb._tcp`), for the sidebar's Shared section. Names are resolved to a
/// connectable host on demand (at connect time).
@MainActor
final class SharedDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate
{
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolving: [NetService: (String?) -> Void] = [:]
    /// Called with the sorted display names whenever the set changes.
    var onChange: (([String]) -> Void)?

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "")
    }

    func stop() { browser.stop() }

    /// Resolve a display name to a connectable host name, on the main actor.
    func resolveHost(named name: String, completion: @escaping (String?) -> Void) {
        guard let service = services.first(where: { $0.name == name }) else {
            completion(nil)
            return
        }
        resolving[service] = completion
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    private func notify() { onChange?(services.map(\.name).sorted()) }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if !services.contains(service) { services.append(service) }
        if !moreComing { notify() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        if !moreComing { notify() }
    }

    // MARK: NetServiceDelegate (resolution)

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.removeValue(forKey: sender)?(sender.hostName)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeValue(forKey: sender)?(nil)
    }
}
