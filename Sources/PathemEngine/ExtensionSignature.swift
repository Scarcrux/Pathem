import CryptoKit
import Foundation
import Security

public struct ExtensionSignature: Codable, Sendable, Equatable {
    public let teamID: String
    public let developer: String
    public let cdHash: Data
    public let fileDigest: Data

    static func verify(_ url: URL, requireDeveloperID: Bool = true) throws -> Self {
        var code: SecStaticCode?
        let failed = ExtensionHost.ExtensionError.invalidSignature
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size > 0, size <= 128 * 1024 * 1024
        else { throw failed }
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
        else { throw failed }
        var rawInformation: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation),
                &rawInformation) == errSecSuccess,
            let information = rawInformation as? [String: Any],
            let hash = information[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty
        else { throw failed }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        var requirement: SecRequirement?
        if requireDeveloperID {
            guard team.utf8.count == 10,
                team.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0)
                })
            else { throw failed }
            let rule =
                "anchor apple generic"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                + " and certificate leaf[subject.OU] = \"\(team)\" and notarized"
            guard
                SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
            else { throw failed }
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
        else { throw failed }
        let certificate = (information[kSecCodeInfoCertificates as String] as? [SecCertificate])?
            .first
        let developer = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        if requireDeveloperID && developer == nil { throw failed }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        var bytesRead = 0
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            bytesRead += chunk.count
            guard bytesRead <= 128 * 1024 * 1024 else { throw failed }
            digest.update(data: chunk)
        }
        return Self(
            teamID: team, developer: developer ?? "", cdHash: hash,
            fileDigest: Data(digest.finalize()))
    }
}

public struct ExtensionApproval: Codable, Sendable, Equatable {
    public let directoryName: String
    public let manifest: ExtensionManifest
    public let signature: ExtensionSignature

    public init(_ candidate: LoadedExtension) throws {
        guard let signature = candidate.signature else {
            throw ExtensionHost.ExtensionError.invalidSignature
        }
        self.directoryName = candidate.directory.lastPathComponent
        self.manifest = candidate.manifest
        self.signature = signature
    }

    public func matches(_ candidate: LoadedExtension) -> Bool {
        directoryName == candidate.directory.lastPathComponent
            && manifest == candidate.manifest && signature == candidate.signature
    }
}
