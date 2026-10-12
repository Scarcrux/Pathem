// Verify a Sparkle EdDSA (Ed25519) signature over a whole file against a base64
// public key. Prints ACCEPT, or REJECT with a reason. Used by verify-release.sh.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
    let publicKey = Data(base64Encoded: args[1]),
    let signature = Data(base64Encoded: args[2]),
    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
else {
    print("REJECT malformed public key or signature")
    exit(2)
}
guard let data = FileManager.default.contents(atPath: args[3]) else {
    print("REJECT unreadable update file")
    exit(2)
}
if key.isValidSignature(signature, for: data) {
    print("ACCEPT")
    exit(0)
}
print("REJECT signature does not match the public key")
exit(1)
