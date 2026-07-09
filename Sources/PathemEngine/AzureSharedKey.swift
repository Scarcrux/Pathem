import CryptoKit
import Foundation

/// Azure Blob "Shared Key" request signing (the classic HMAC-SHA256 scheme).
///
/// Pure and deterministic: the caller hands over the request pieces and the date,
/// and gets back the exact string to sign and the `Authorization` header value. No
/// I/O happens here, so it is unit-testable against fixed HMAC vectors.
///
/// Reference: "Authorize with Shared Key" (Blob, Queue, File). We always send
/// `x-ms-date` (so the standard Date line stays empty) and `x-ms-version`.
public enum AzureSharedKey {
    /// The REST version we send as `x-ms-version` and sign against.
    public static let apiVersion = "2021-08-06"

    /// RFC 1123 date in GMT, e.g. "Sun, 06 Nov 1994 08:49:37 GMT" -- the format Azure
    /// requires for `x-ms-date`.
    public static func rfc1123(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        let c = cal.dateComponents([.weekday, .day, .month, .year, .hour, .minute, .second], from: date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        return String(
            format: "%@, %02d %@ %04d %02d:%02d:%02d GMT",
            days[(c.weekday ?? 1) - 1], c.day ?? 1, months[(c.month ?? 1) - 1], c.year ?? 1970,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The canonicalized resource: "/account" + the URL path, then each query
    /// parameter (name lowercased, sorted) on its own line as "name:value" (repeated
    /// values comma-joined). Query values here are the *decoded* values Azure will see.
    public static func canonicalizedResource(
        account: String, path: String, query: [(name: String, value: String)]
    ) -> String {
        var resource = "/\(account)\(path)"
        // Group repeated params, lowercased names, sorted.
        var grouped: [String: [String]] = [:]
        for (name, value) in query { grouped[name.lowercased(), default: []].append(value) }
        for name in grouped.keys.sorted() {
            resource += "\n\(name):\(grouped[name]!.joined(separator: ","))"
        }
        return resource
    }

    /// Build the string-to-sign for a Blob request. `contentLength` of 0 signs as an
    /// empty field (the rule for version 2015-02-21 and later, which Azure applies on
    /// its side too), so a body-less request matches whether or not curl sends a
    /// `Content-Length: 0`.
    public static func stringToSign(
        verb: String, contentLength: Int, contentType: String, xmsHeaders: [String: String],
        canonicalizedResource: String
    ) -> String {
        var s = verb + "\n"
        s += "\n"  // Content-Encoding
        s += "\n"  // Content-Language
        s += (contentLength == 0 ? "" : String(contentLength)) + "\n"  // Content-Length
        s += "\n"  // Content-MD5
        s += contentType + "\n"  // Content-Type
        s += "\n"  // Date (empty: we use x-ms-date)
        s += "\n"  // If-Modified-Since
        s += "\n"  // If-Match
        s += "\n"  // If-None-Match
        s += "\n"  // If-Unmodified-Since
        s += "\n"  // Range
        for (name, value) in
            xmsHeaders
            .map({ ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
            .sorted(by: { $0.0 < $1.0 })
        {
            s += "\(name):\(value)\n"  // canonicalized headers, each terminated by "\n"
        }
        s += canonicalizedResource
        return s
    }

    /// The base64 HMAC-SHA256 signature of `stringToSign` under the base64-encoded
    /// account `key`. Returns nil when the key isn't valid base64.
    public static func signature(key: String, stringToSign: String) -> String? {
        guard let keyData = Data(base64Encoded: key) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8), using: SymmetricKey(data: keyData))
        return Data(mac).base64EncodedString()
    }

    /// The full `Authorization` header value: "SharedKey account:signature", or nil if
    /// the key isn't valid base64.
    public static func authorization(account: String, key: String, stringToSign: String) -> String? {
        guard let sig = signature(key: key, stringToSign: stringToSign) else { return nil }
        return "SharedKey \(account):\(sig)"
    }
}
