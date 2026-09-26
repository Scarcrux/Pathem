import Testing

@testable import PathemEngine

@Suite struct AzureEndpointTests {
    @Test func customEndpointHonorsExplicitPort() {
        let connection = RemoteConnection(
            name: "emulator", proto: .azure, host: "127.0.0.1", port: 10_000,
            user: "devstoreaccount1")
        #expect(AzureBlobProvider.base(connection) == "https://127.0.0.1:10000")
    }

    @Test func standardEndpointOmitsDefaultPort() {
        let connection = RemoteConnection(
            name: "azure", proto: .azure, host: "", user: "storageaccount")
        #expect(
            AzureBlobProvider.base(connection) == "https://storageaccount.blob.core.windows.net")
    }
}
