// A throwaway Sparkle EdDSA key for scripts/e2e-update.sh: writes the private seed to the file named, prints the public key.
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
