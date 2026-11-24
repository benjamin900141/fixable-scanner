import CryptoKit
import Foundation

enum ChatKey {
    static func of(app: String, name: String, firstLine: String, accessibilityId: String) -> String {
        let id = accessibilityId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty && id != name && !id.contains(":id/") { return String(id.prefix(200)) }
        let digest = SHA256.hash(data: Data("\(app)\n\(name)\n\(firstLine)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}
