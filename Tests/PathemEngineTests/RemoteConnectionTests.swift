import Foundation
import Testing

@testable import PathemEngine

@Suite struct RemoteConnectionTests {
    @Test func colorLabelAndLocalPathRoundTrip() throws {
        let original = RemoteConnection(
            name: "Site", proto: .sftp, host: "example.com", colorLabel: "blue", localPath: "/Users/me/site")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: data)
        #expect(decoded.colorLabel == "blue")
        #expect(decoded.localPath == "/Users/me/site")
        #expect(FileTag.Color(nameKey: decoded.colorLabel) == .blue)
    }

    @Test func olderJSONWithoutNewFieldsStillDecodes() throws {
        let json = #"{"name":"Old","proto":"ftp","host":"h.example.com"}"#
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: Data(json.utf8))
        #expect(decoded.colorLabel.isEmpty)  // defaults, not a decode failure
        #expect(decoded.localPath.isEmpty)
        #expect(decoded.bookmarks.isEmpty)  // absent bookmarks default to none
    }

    @Test func bookmarksRoundTrip() throws {
        var original = RemoteConnection(name: "Site", proto: .sftp, host: "example.com")
        original.bookmarks = [
            RemoteBookmark(name: "Logs", remotePath: "/var/log"),
            RemoteBookmark(name: "Releases", remotePath: "/srv/www/releases"),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: data)
        #expect(decoded.bookmarks == original.bookmarks)
        #expect(decoded.bookmarks[1].remotePath == "/srv/www/releases")
    }

    @Test func tagColorNameKeyRoundTrips() {
        for color in FileTag.Color.allCases {
            #expect(FileTag.Color(nameKey: color.nameKey) == color)
        }
        #expect(FileTag.Color(nameKey: "bogus") == nil)
    }

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

    @Test func keyFileRoundTripsAndDefaultsEmpty() throws {
        // An older connections.json (no keyFile) decodes to "" (password/agent auth).
        let old = try JSONDecoder().decode(
            RemoteConnection.self, from: Data(#"{ "host": "ec2.example.com", "proto": "sftp" }"#.utf8))
        #expect(old.keyFile == "")
        // A saved key file round-trips.
        let conn = RemoteConnection(name: "EC2", proto: .sftp, host: "ec2.example.com", keyFile: "~/.ssh/ec2.pem")
        let back = try JSONDecoder().decode(RemoteConnection.self, from: JSONEncoder().encode(conn))
        #expect(back.keyFile == "~/.ssh/ec2.pem")
    }
}
