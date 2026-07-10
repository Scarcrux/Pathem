import Foundation
import Testing

@testable import TorrentKit

@Suite struct UPnPTests {
    @Test func searchRequestIsWellFormed() {
        let text = String(data: UPnP.searchRequest(), encoding: .utf8)!
        #expect(text.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        #expect(text.contains("MAN: \"ssdp:discover\""))
        #expect(text.contains("InternetGatewayDevice:1"))
        #expect(text.hasSuffix("\r\n\r\n"))  // blank line terminator
    }

    @Test func parsesLocationHeaderCaseInsensitively() {
        let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLocation: http://192.168.1.1:5000/desc.xml\r\nST: upnp:rootdevice\r\n\r\n"
        #expect(UPnP.parseLocation(Data(response.utf8)) == "http://192.168.1.1:5000/desc.xml")
        #expect(UPnP.parseLocation(Data("no location here".utf8)) == nil)
    }

    @Test func findsControlURLAndResolvesRelative() {
        let xml = """
            <root><device><serviceList>
            <service>
              <serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
              <controlURL>/ignore</controlURL>
            </service>
            <service>
              <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
              <controlURL>/upnp/control/wan</controlURL>
            </service>
            </serviceList></device></root>
            """
        let base = URL(string: "http://192.168.1.1:5000/desc.xml")!
        let result = UPnP.controlURL(fromDescription: Data(xml.utf8), descriptionURL: base)
        #expect(result?.url.absoluteString == "http://192.168.1.1:5000/upnp/control/wan")
        #expect(result?.serviceType.contains("WANIPConnection") == true)
    }

    @Test func returnsNilWhenNoWANService() {
        let xml = "<root><device><serviceList><service><serviceType>urn:other:1</serviceType><controlURL>/x</controlURL></service></serviceList></device></root>"
        #expect(UPnP.controlURL(fromDescription: Data(xml.utf8), descriptionURL: URL(string: "http://x/")!) == nil)
    }

    @Test func soapBodyAndActionAreCorrect() {
        let type = "urn:schemas-upnp-org:service:WANIPConnection:1"
        #expect(UPnP.addPortMappingAction(serviceType: type) == "\"\(type)#AddPortMapping\"")
        let body = String(data: UPnP.addPortMappingBody(
            serviceType: type, externalPort: 6881, internalPort: 6881, internalClient: "192.168.1.42"), encoding: .utf8)!
        #expect(body.contains("<u:AddPortMapping xmlns:u=\"\(type)\">"))
        #expect(body.contains("<NewExternalPort>6881</NewExternalPort>"))
        #expect(body.contains("<NewInternalClient>192.168.1.42</NewInternalClient>"))
        #expect(body.contains("<NewProtocol>TCP</NewProtocol>"))
    }
}
