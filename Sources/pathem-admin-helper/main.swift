import Darwin
import Dispatch
import Foundation
import OSLog
import PathemEngine

private let adminLog = Logger(subsystem: "com.scarcrux.pathem", category: "admin")

private final class AdminListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection peer: NSXPCConnection
    ) -> Bool {
        // Foundation checks the exact signing requirement against the XPC sender's audit
        // token. Its audit session and effective user also have to describe a user process.
        let session = peer.auditSessionIdentifier
        let isRoot = peer.effectiveUserIdentifier == 0
        let validSession = session != 0 && session != .max
        guard !isRoot, validSession else {
            adminLog.notice(
                "Admin listener rejected peer root=\(isRoot, privacy: .public) validAuditSession=\(validSession, privacy: .public)"
            )
            return false
        }
        peer.exportedInterface = NSXPCInterface(with: AdminFileServiceProtocol.self)
        peer.exportedObject = AdminFileService(
            trashRoot: AdminTrashRoot.homeTrash(for: peer.effectiveUserIdentifier),
            verifyAuthorization: AdminAuthorization.verify)
        adminLog.notice("Admin listener accepted peer after audit session checks")
        peer.resume()
        return true
    }
}

// This binary is started by launchd only after the user approves Pathem in System Settings.
guard geteuid() == 0, AdminAuthorization.ensureRightInstalled() else {
    adminLog.error(
        "Admin helper startup refused by privilege, signature, or authorization-right check")
    exit(77)
}
let listener = NSXPCListener(machServiceName: AdminHelperIdentity.serviceName)
private let delegate = AdminListenerDelegate()
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(
    AdminHelperIdentity.signingRequirement(for: AdminHelperIdentity.appIdentifier))
listener.resume()
adminLog.notice("Admin helper listener resumed with signed-peer requirement")
withExtendedLifetime(delegate) { dispatchMain() }
