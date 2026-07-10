import Foundation

/// UPnP Internet Gateway Device (IGD) port mapping: a fallback to NAT-PMP for routers that speak
/// only UPnP. The flow is SSDP discovery -> fetch the device description -> SOAP AddPortMapping.
/// The message construction and parsing here are pure and unit-tested; UPnPClient does the
/// multicast + HTTP.
public enum UPnP {
    public static let ssdpHost = "239.255.255.250"
    public static let ssdpPort: UInt16 = 1900

    /// The SSDP M-SEARCH datagram that asks gateways to announce themselves.
    public static func searchRequest() -> Data {
        let lines = [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: 2",
            "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1",
            "", "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// Extract the `LOCATION` header (the device description URL) from an SSDP response.
    public static func parseLocation(_ response: Data) -> String? {
        guard let text = String(data: response, encoding: .utf8) else { return nil }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("location:") {
                return String(line.dropFirst("location:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Find the control URL of a WAN IP/PPP connection service in a device description, resolved
    /// against the description's URL. Returns the URL and the matched service type (needed for the
    /// SOAP action namespace).
    public static func controlURL(fromDescription xml: Data, descriptionURL: URL) -> (url: URL, serviceType: String)? {
        guard let text = String(data: xml, encoding: .utf8) else { return nil }
        for block in serviceBlocks(text) {
            guard let type = value(of: "serviceType", in: block),
                type.contains("WANIPConnection") || type.contains("WANPPPConnection"),
                let control = value(of: "controlURL", in: block)
            else { continue }
            let resolved: URL? =
                control.hasPrefix("http")
                ? URL(string: control) : URL(string: control, relativeTo: descriptionURL)?.absoluteURL
            if let resolved { return (resolved, type) }
        }
        return nil
    }

    /// The SOAPAction header value for AddPortMapping on a given service type.
    public static func addPortMappingAction(serviceType: String) -> String {
        "\"\(serviceType)#AddPortMapping\""
    }

    /// The SOAP body that maps an external port to us for `leaseDuration` seconds.
    public static func addPortMappingBody(
        serviceType: String, externalPort: UInt16, internalPort: UInt16, internalClient: String,
        description: String = "Pathem", leaseDuration: Int = 3600
    ) -> Data {
        let body = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
            <u:AddPortMapping xmlns:u="\(serviceType)">
            <NewRemoteHost></NewRemoteHost>
            <NewExternalPort>\(externalPort)</NewExternalPort>
            <NewProtocol>TCP</NewProtocol>
            <NewInternalPort>\(internalPort)</NewInternalPort>
            <NewInternalClient>\(internalClient)</NewInternalClient>
            <NewEnabled>1</NewEnabled>
            <NewPortMappingDescription>\(description)</NewPortMappingDescription>
            <NewLeaseDuration>\(leaseDuration)</NewLeaseDuration>
            </u:AddPortMapping>
            </s:Body>
            </s:Envelope>
            """
        return Data(body.utf8)
    }

    // MARK: tiny XML scanning helpers (a full parser is overkill for these fixed shapes)

    private static func serviceBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<service>"), let close = rest.range(of: "</service>") {
            if close.lowerBound > open.upperBound {
                blocks.append(String(rest[open.upperBound..<close.lowerBound]))
            }
            rest = rest[close.upperBound...]
        }
        return blocks
    }

    private static func value(of tag: String, in block: String) -> String? {
        guard let open = block.range(of: "<\(tag)>"), let close = block.range(of: "</\(tag)>"),
            close.lowerBound > open.upperBound
        else { return nil }
        return String(block[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
