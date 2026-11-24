import Foundation

enum Bookmark {
    private static let key = "fixable.scan.bookmark"

    static func save(token: String, runId: String, months: Int, chatKey: String, screenId: String) {
        let value = ["token": token, "runId": runId, "months": String(months), "chatKey": chatKey, "screenId": screenId]
        UserDefaults.standard.set(value, forKey: key)
    }

    static func read() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
