import Foundation
import Testing

@testable import PathemEngine

@Suite struct AdminFileServiceTests {
    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        private let token: Data
        init(token: Data) { self.token = token }

        func listener(
            _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
        ) -> Bool {
            let token = token
            connection.exportedInterface = NSXPCInterface(with: AdminFileServiceProtocol.self)
            connection.exportedObject = AdminFileService { $0 == token }
            connection.resume()
            return true
        }
    }

    @Test(.timeLimit(.minutes(1))) func unprivilegedXPCRequiresAuthorizationAndLocksAgain()
        async throws
    {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("pathem-admin-service-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let child = try canonicalAdminFixture(scratch).appendingPathComponent("created")
        let request = try JSONEncoder().encode(
            AdminFileRequest(operation: .createDirectory, source: child.path))
        let controller = ListenerDelegate(token: Data(repeating: 0x25, count: 32))
        let listener = NSXPCListener.anonymous()
        listener.delegate = controller
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AdminFileServiceProtocol.self)
        connection.resume()
        defer {
            connection.invalidate()
            withExtendedLifetime(controller) {}
        }

        func perform() async -> Bool {
            await withCheckedContinuation { continuation in
                let proxy =
                    connection.remoteObjectProxyWithErrorHandler { _ in
                        continuation.resume(returning: false)
                    } as! AdminFileServiceProtocol
                proxy.perform(request) { _, err in continuation.resume(returning: err == nil) }
            }
        }

        func authorize(_ value: UInt8) async -> Bool {
            await withCheckedContinuation { continuation in
                let proxy =
                    connection.remoteObjectProxyWithErrorHandler { _ in
                        continuation.resume(returning: false)
                    } as! AdminFileServiceProtocol
                proxy.authorize(Data(repeating: value, count: 32)) {
                    continuation.resume(returning: $0)
                }
            }
        }

        #expect(await perform() == false)
        #expect(!fm.fileExists(atPath: child.path))
        #expect(await authorize(0) == false)
        #expect(await authorize(0x25))
        try #require(await perform())
        try #require(fm.fileExists(atPath: child.path))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { _ in
                    continuation.resume()
                } as! AdminFileServiceProtocol
            proxy.lockSession { continuation.resume() }
        }
        try fm.removeItem(at: child)
        #expect(await perform() == false)
        #expect(!fm.fileExists(atPath: child.path))
    }
}
