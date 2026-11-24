import Foundation

enum Poster {
    static let site = URL(string: "https://hearty-mammoth-35.convex.site")!

    static func screen(token: String, app: String, chatKey: String, screenId: String, text: String) async -> Bool {
        await post("/device/screen", token: token, body: ["app": app, "chatKey": chatKey, "screenId": screenId, "text": text])
    }

    static func calendar(token: String, chatKey: String, screenId: String, title: String, start: Double, allDay: Bool) async -> Bool {
        await post("/device/calendar-row", token: token, body: [
            "app": "calendar", "chatKey": chatKey, "screenId": screenId, "title": title, "start": start, "allDay": allDay,
        ])
    }

    static func stop(token: String) async -> Bool {
        await post("/device/stop", token: token, body: [:])
    }

    static func finish(token: String, unreadable: Int) async -> Bool {
        await post("/device/finish", token: token, body: ["finished": true, "unreadable": unreadable])
    }

    private static func post(_ path: String, token: String, body: [String: Any]) async -> Bool {
        var request = URLRequest(url: site.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        if path == "/device/screen" { request.url = site.appendingPathComponent("device/screen") }
        if path == "/device/finish" { request.url = site.appendingPathComponent("device/finish") }
        if path == "/device/stop" { request.url = site.appendingPathComponent("device/stop") }
        if path == "/device/calendar-row" { request.url = site.appendingPathComponent("device/screen") }
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
