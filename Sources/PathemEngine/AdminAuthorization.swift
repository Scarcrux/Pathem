import Foundation
import Security

public enum AdminHelperIdentity {
    public static let team = "K466Z7J2AS"
    public static let appIdentifier = "com.scarcrux.pathem"
    public static let serviceName = "com.scarcrux.pathem.admin-helper"
    public static let plistName = serviceName + ".plist"

    public static func signingRequirement(for identifier: String) -> String {
        """
        anchor apple generic and identifier "\(identifier)" and         certificate leaf[subject.OU] = "\(team)" and         certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """
    }

    public static func currentProcessMatches(_ identifier: String) -> Bool {
        var requirement: SecRequirement?
        let expression = signingRequirement(for: identifier)
        guard
            SecRequirementCreateWithString(expression as CFString, [], &requirement)
                == errSecSuccess,
            let requirement
        else { return false }
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return false }
        return SecCodeCheckValidity(selfCode, [], requirement) == errSecSuccess
    }
}

public enum AdminAuthorization {
    public static let rightName = "com.scarcrux.pathem.admin"
    // This system-wide rule uses the default five-minute Admin duration. The
    // per-connection session uses the selected duration and destroys the app's
    // authorization reference immediately after the handshake.
    static let credentialTimeout = 300
    static var expectedRule: [String: Any] {
        [
            "class": "user", "group": "admin", "shared": true,
            "timeout": credentialTimeout, "authenticate-user": true,
            "allow-root": false, "session-owner": false,
        ]
    }

    /// Called only by the already-approved, signed launch daemon. Migrate the
    /// old Pathem rule in place and preserve any unrecognized policy.
    public static func ensureRightInstalled() -> Bool {
        guard geteuid() == 0,
            AdminHelperIdentity.currentProcessMatches(AdminHelperIdentity.serviceName)
        else { return false }
        if let definition = rightDefinition() {
            if isExpectedRule(definition) { return true }
            guard isLegacyRule(definition) else { return false }
        }
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
            let authorization
        else { return false }
        defer { AuthorizationFree(authorization, []) }
        let result = AuthorizationRightSet(
            authorization, rightName, expectedRule as CFDictionary,
            "Allow Pathem to perform administrator file operations." as CFString, nil, nil)
        guard result == errAuthorizationSuccess, let definition = rightDefinition() else {
            return false
        }
        return isExpectedRule(definition)
    }

    /// A peer must already have extended its rights. The daemon never asks to extend them.
    public static func verify(_ data: Data) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size,
            let definition = rightDefinition(), isExpectedRule(definition)
        else { return false }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
        var authorization: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &authorization) == errAuthorizationSuccess,
            let authorization
        else { return false }
        defer { AuthorizationFree(authorization, []) }
        return copyRight(authorization, []) == errAuthorizationSuccess
    }

    private static func rightDefinition() -> [String: Any]? {
        var definition: CFDictionary?
        guard AuthorizationRightGet(rightName, &definition) == errAuthorizationSuccess
        else { return nil }
        return definition as? [String: Any]
    }

    static func isExpectedRule(_ definition: [String: Any]) -> Bool {
        definition["class"] as? String == "user"
            && definition["group"] as? String == "admin"
            && definition["shared"] as? Bool == true
            && definition["timeout"] as? Int == credentialTimeout
            && definition["authenticate-user"] as? Bool == true
            && definition["allow-root"] as? Bool == false
            && definition["session-owner"] as? Bool == false
            && definition["rule"] == nil
            && definition["mechanisms"] == nil
    }

    static func isLegacyRule(_ definition: [String: Any]) -> Bool {
        guard definition["class"] as? String == "rule" else { return false }
        return definition["rule"] as? [String] == ["authenticate-admin"]
            || definition["rule"] as? String == "authenticate-admin"
    }

    fileprivate static func copyRight(
        _ authorization: AuthorizationRef, _ flags: AuthorizationFlags
    )
        -> OSStatus
    {
        rightName.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { item in
                var rights = AuthorizationRights(count: 1, items: item)
                return AuthorizationCopyRights(authorization, &rights, nil, flags, nil)
            }
        }
    }
}

/// Retain this object through the XPC authorization reply. Discarding it revokes the
/// original system authorization. The helper then owns the separate time-limited session.
public final class AdminAuthorizationCredential: @unchecked Sendable {
    public let externalForm: Data
    private let authorization: AuthorizationRef

    public init() throws {
        var reference: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &reference)
        guard status == errAuthorizationSuccess, let reference else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        do {
            let granted = AdminAuthorization.copyRight(
                reference, [.extendRights, .interactionAllowed])
            if granted == errAuthorizationCanceled { throw CancellationError() }
            guard granted == errAuthorizationSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(granted))
            }
            var form = AuthorizationExternalForm()
            let externalized = AuthorizationMakeExternalForm(reference, &form)
            guard externalized == errAuthorizationSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(externalized))
            }
            externalForm = withUnsafeBytes(of: &form) { Data($0) }
            authorization = reference
        } catch {
            AuthorizationFree(reference, [.destroyRights])
            throw error
        }
    }

    deinit { AuthorizationFree(authorization, [.destroyRights]) }
}
