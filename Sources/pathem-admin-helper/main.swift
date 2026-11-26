import Darwin
import Dispatch
import Foundation
import PathemEngine

private final class AdminListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection peer: NSXPCConnection
    ) -> Bool {
        // Foundation checks the exact signing requirement against the XPC sender's audit
        // token. Its audit session and effective user also have to describe a user process.
        let session = peer.auditSessionIdentifier
        guard peer.effectiveUserIdentifier != 0, session != 0, session != .max else { return false }
        peer.exportedInterface = NSXPCInterface(with: AdminFileServiceProtocol.self)
        peer.exportedObject = AdminFileService(
            trashRoot: AdminTrashRoot.homeTrash(for: peer.effectiveUserIdentifier),
            verifyAuthorization: AdminAuthorization.verify)
        peer.resume()
        return true
    }
}

// This binary is started by launchd only after the user approves Pathem in System Settings.
guard geteuid() == 0, AdminAuthorization.ensureRightInstalled() else { exit(77) }
let listener = NSXPCListener(machServiceName: AdminHelperIdentity.serviceName)
private let delegate = AdminListenerDelegate()
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(
    AdminHelperIdentity.signingRequirement(for: AdminHelperIdentity.appIdentifier))
listener.resume()
withExtendedLifetime(delegate) { dispatchMain() }
