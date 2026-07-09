import Foundation
import Testing

@testable import PathemEngine

@Suite struct S3ProviderTests {
    /// Any S3-compatible service (Backblaze B2, Google Cloud Storage's XML API, Wasabi,
    /// DigitalOcean Spaces, MinIO) works by setting the connection's host to that provider's
    /// endpoint; the S3 provider then uses path-style addressing + SigV4 against it.
    @Test func customEndpointHostForS3CompatibleProviders() {
        for endpoint in [
            "s3.us-west-002.backblazeb2.com",  // Backblaze B2
            "storage.googleapis.com",  // Google Cloud Storage (S3-compatible XML API)
            "s3.wasabisys.com",  // Wasabi
            "nyc3.digitaloceanspaces.com",  // DigitalOcean Spaces
        ] {
            let connection = RemoteConnection(name: "x", proto: .s3, host: endpoint, region: "us-east-1")
            #expect(S3Provider.host(connection) == endpoint)
            #expect(RemoteConnection.isValidHost(endpoint))  // a real, non-smuggling host
        }
    }

    @Test func awsDefaultHostDerivesFromRegion() {
        let connection = RemoteConnection(name: "x", proto: .s3, host: "", region: "eu-west-1")
        #expect(S3Provider.host(connection) == "s3.eu-west-1.amazonaws.com")
    }
}
