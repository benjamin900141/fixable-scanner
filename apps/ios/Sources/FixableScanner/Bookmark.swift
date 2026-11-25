import Foundation

enum Bookmark {
    private static let key = "fixable.scan.bookmark"

    static func save(token: String, runId: String, months: Int, chatKey: String, screenId: String, chat: String) {
        let value = ["token": token, "runId": runId, "months": String(months), "chatKey": chatKey, "screenId": screenId, "chat": chat]
        UserDefaults.standard.set(value, forKey: key)
    }

    static func screenNumber(chatKey: String, screenId: String) -> Int {
        let prefix = chatKey + ":"
        guard !chatKey.isEmpty, screenId.hasPrefix(prefix) else { return -1 }
        let rest = screenId.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isNumber }
        return Int(digits) ?? -1
    }

    static func read() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
