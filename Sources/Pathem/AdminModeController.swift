import AppKit
import OSLog
import PathemEngine
import ServiceManagement

private let adminLog = Logger(subsystem: "com.scarcrux.pathem", category: "admin")

extension Notification.Name {
    static let pathemAdminModeChanged = Notification.Name("pathem.adminModeChanged")
}

/// The UI never attempts an elevated operation unless someone explicitly unlocked this session.
@MainActor
final class AdminModeController: NSObject {
    static let shared = AdminModeController()
    static let isSupported =
        Bundle.main.bundleURL.pathExtension == "app"
        && AdminHelperIdentity.currentProcessMatches(AdminHelperIdentity.appIdentifier)

    private let service = SMAppService.daemon(plistName: AdminHelperIdentity.plistName)
    private var connection: NSXPCConnection?
    private var timeout: Task<Void, Never>?
    private var generation = 0
    private(set) var isUnlocked = false
    private(set) var isUnlocking = false

    private let buildKey = "pathem.adminHelperEnrollmentBuild"
    private var currentBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    var needsSetup: Bool {
        service.status != .enabled
            || currentBuild != UserDefaults.standard.string(forKey: buildKey)
    }

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(lock), name: NSWorkspace.willSleepNotification, object: nil)
    }

    /// Registration is only called from the explicit setup action in Settings or the menu.
    func setUp() async throws {
        guard Self.isSupported, let currentBuild else { throw POSIXError(.EACCES) }
        if service.status == .enabled,
            currentBuild != UserDefaults.standard.string(forKey: buildKey)
        {
            lock()
            try await service.unregister()
        }
        if service.status == .notRegistered || service.status == .notFound {
            try service.register()
            UserDefaults.standard.set(currentBuild, forKey: buildKey)
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func remove() async throws {
        guard Self.isSupported else { throw POSIXError(.EACCES) }
        lock()
        if service.status != .notRegistered && service.status != .notFound {
            try await service.unregister()
        }
        UserDefaults.standard.removeObject(forKey: buildKey)
    }

    func unlock(minutes: Int) async throws {
        guard Self.isSupported, !needsSetup, !isUnlocking, !isUnlocked
        else { throw POSIXError(.EACCES) }
        isUnlocking = true
        defer { isUnlocking = false }
        let duration = min(max(1, minutes), 15) * 60
        let expected = generation
        let peer = NSXPCConnection(
            machServiceName: AdminHelperIdentity.serviceName, options: .privileged)
        adminLog.notice(
            "Unlock created privileged XPC connection generation=\(expected, privacy: .public)")
        peer.remoteObjectInterface = NSXPCInterface(with: AdminFileServiceProtocol.self)
        peer.setCodeSigningRequirement(
            AdminHelperIdentity.signingRequirement(for: AdminHelperIdentity.serviceName))
        peer.interruptionHandler = { [weak self] in
            adminLog.notice("Admin XPC interrupted generation=\(expected, privacy: .public)")
            Task { @MainActor in self?.lockIfCurrent(expected) }
        }
        peer.invalidationHandler = { [weak self] in
            adminLog.notice("Admin XPC invalidated generation=\(expected, privacy: .public)")
            Task { @MainActor in self?.lockIfCurrent(expected) }
        }
        peer.resume()
        var retained = false
        defer { if !retained { peer.invalidate() } }

        // The running helper prepares its Authorization Services right before accepting requests.
        let version = try await Self.call(peer) { proxy, done in
            proxy.version { done(.success($0)) }
        }
        adminLog.notice(
            "Admin XPC version reply version=\(version, privacy: .public) generation=\(expected, privacy: .public)"
        )
        guard version == 1, generation == expected else { throw POSIXError(.EPROTO) }
        let proof = try await Task.detached(priority: .userInitiated) {
            try AdminAuthorizationCredential()
        }.value
        guard generation == expected else { throw CancellationError() }
        let accepted = try await Self.call(peer) { proxy, done in
            proxy.authorize(proof.externalForm, duration: duration) { value in
                withExtendedLifetime(proof) { done(.success(value)) }
            }
        }
        adminLog.notice(
            "Admin XPC authorization reply accepted=\(accepted, privacy: .public) generation=\(expected, privacy: .public)"
        )
        guard accepted, generation == expected else { throw POSIXError(.EACCES) }

        connection = peer
        retained = true
        isUnlocked = true
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.lockIfCurrent(expected)
        }
        announceChange()
    }

    @objc func lock() {
        generation += 1
        timeout?.cancel()
        timeout = nil
        let peer = connection
        connection = nil
        if let proxy = peer?.remoteObjectProxy as? AdminFileServiceProtocol {
            proxy.lockSession {}
        }
        peer?.invalidate()
        guard isUnlocked else { return }
        isUnlocked = false
        announceChange()
    }

    private func lockIfCurrent(_ expected: Int) {
        if generation == expected { lock() }
    }

    /// A failed regular operation must have returned a permission errno. No other error
    /// triggers a privileged request, and a successful regular operation needs no request.
    func mayRetry(_ error: Error) -> Bool {
        let permissionFailure = AdminFileRequest.isPermissionFailure(error)
        let retry = isUnlocked && permissionFailure
        let chain = Self.errorChain(error)
        adminLog.notice(
            "Admin retry decision retry=\(retry, privacy: .public) unlocked=\(self.isUnlocked, privacy: .public) connected=\(self.connection != nil, privacy: .public) permissionFailure=\(permissionFailure, privacy: .public) errors=\(chain, privacy: .public)"
        )
        return retry
    }

    nonisolated private static func errorChain(_ error: Error) -> String {
        var chain: [String] = []
        var visited = Set<ObjectIdentifier>()
        var current: NSError? = error as NSError
        while let entry = current, visited.insert(ObjectIdentifier(entry)).inserted {
            chain.append("\(entry.domain):\(entry.code)")
            current = entry.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain.joined(separator: " -> ")
    }

    func perform(_ request: AdminFileRequest) async throws -> Data {
        let operation = request.operation.rawValue
        adminLog.notice(
            "Admin perform guard operation=\(operation, privacy: .public) unlocked=\(self.isUnlocked, privacy: .public) connected=\(self.connection != nil, privacy: .public) generation=\(self.generation, privacy: .public)"
        )
        guard isUnlocked, let connection else { throw POSIXError(.EACCES) }
        try request.validate()
        let encoded = try JSONEncoder().encode(request)
        do {
            let result: Data = try await Self.call(connection) { proxy, done in
                proxy.perform(encoded) { response, error in
                    if let error {
                        done(.failure(error))
                    } else if let response {
                        done(.success(response))
                    } else {
                        done(.failure(POSIXError(.EPROTO)))
                    }
                }
            }
            record(request, error: nil)
            return result
        } catch {
            record(request, error: error)
            throw error
        }
    }

    private func record(_ request: AdminFileRequest, error: Error?) {
        OperationLogger.shared.record(
            OperationRecord(
                operation: request.operation.rawValue, sources: [request.source],
                destination: request.destination, outcome: error == nil ? .ok : .failed,
                error: error?.localizedDescription, admin: true))
    }

    private func announceChange() {
        NotificationCenter.default.post(name: .pathemAdminModeChanged, object: nil)
    }

    private static func call<Value: Sendable>(
        _ connection: NSXPCConnection,
        _ request: (AdminFileServiceProtocol, @escaping @Sendable (Result<Value, Error>) -> Void) ->
            Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let reply = AdminXPCReply(continuation)
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({
                    adminLog.error(
                        "Admin XPC proxy error errors=\(Self.errorChain($0), privacy: .public)")
                    reply.finish(.failure($0))
                }) as? AdminFileServiceProtocol
            else {
                reply.finish(.failure(POSIXError(.ENOTCONN)))
                return
            }
            request(proxy) { reply.finish($0) }
        }
    }
}

private final class AdminXPCReply<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        let pending = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume(with: result)
    }
}
