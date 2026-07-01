import Foundation
import Testing

@testable import PathemEngine

@Suite struct RemoteConnectionTests {
    @Test func acceptsPlainHosts() {
        #expect(RemoteConnection.isValidHost("ftp.example.com"))
        #expect(RemoteConnection.isValidHost("192.168.1.10"))
        #expect(RemoteConnection.isValidHost("[::1]"))
        #expect(RemoteConnection.isValidHost("host-1.sub.example.com"))
    }

    @Test func rejectsAuthoritySmuggling() {
        // The credential-redirection vectors the audit flagged.
        #expect(!RemoteConnection.isValidHost("decoy.test@attacker.host"))
        #expect(!RemoteConnection.isValidHost("a/b"))
        #expect(!RemoteConnection.isValidHost("a b"))
        #expect(!RemoteConnection.isValidHost("host:21"))
        #expect(!RemoteConnection.isValidHost("host?x"))
        #expect(!RemoteConnection.isValidHost("host#x"))
        #expect(!RemoteConnection.isValidHost(""))
    }

    @Test func acceptsPlainLoginNames() {
        #expect(RemoteConnection.isValidUser(""))  // empty -> anonymous
        #expect(RemoteConnection.isValidUser("alice"))
        #expect(RemoteConnection.isValidUser("build-bot_01"))
        #expect(RemoteConnection.isValidUser("user.name"))
    }

    @Test func rejectsUserOptionSmuggling() {
        // A user starting with "-" would be parsed by ssh/sftp as an option once it is
        // interpolated into the "user@host" argv token (e.g. -oProxyCommand=... -> RCE).
        #expect(!RemoteConnection.isValidUser("-oProxyCommand=touch /tmp/pwned;false"))
        #expect(!RemoteConnection.isValidUser("-l"))
        #expect(!RemoteConnection.isValidUser("a@b"))  // @ would split the authority
        #expect(!RemoteConnection.isValidUser("has space"))
        #expect(!RemoteConnection.isValidUser("line\nbreak"))
    }

    @Test func tolerantDecodeKeepsOtherConnectionsAlive() throws {
        // A partial entry (only host) decodes with defaults instead of failing the array.
        let json = """
            [ { "host": "a.example.com" },
              { "name": "B", "proto": "ftps", "host": "b.example.com", "port": 990, "user": "x", "path": "/pub" } ]
            """
        let conns = try JSONDecoder().decode([RemoteConnection].self, from: Data(json.utf8))
        #expect(conns.count == 2)
        #expect(conns[0].host == "a.example.com")
        #expect(conns[0].proto == .ftp)  // defaulted
        #expect(conns[0].path == "/")  // defaulted
        #expect(conns[1].proto == .ftps)
        #expect(conns[1].effectivePort == 990)
    }
}
