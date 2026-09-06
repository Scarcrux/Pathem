import Foundation

/// Normalizes a resolved Bonjour host name for use in a URL.
public enum BonjourHost {
    /// `NetService.hostName` returns the fully-qualified name with the DNS root label's trailing
    /// dot ("Studio-Mac.local."). Left on, it lands in the `smb://` URL and the mount
    /// fails ("Couldn't mount ..."), so strip trailing dots before handing the host on. Idempotent,
    /// and leaves an already-clean name, an IP address, or an empty string unchanged.
    public static func normalized(_ host: String) -> String {
        var result = host
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }
}
