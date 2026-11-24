import Foundation

enum ChatScan {
    private static let unreadLabels = ["Mark as unread", "标为未读", "標示為未讀"]

    static func read(token: String, months: Int, ticked: Set<String>, onNames: @escaping @MainActor ([String]) -> Void) async -> String {
        if let problem = await PhoneScreen.connect() {
            await Poster.stop(token: token)
            return problem
        }
        let apps = await PhoneScreen.apps()
        if apps.isEmpty {
            await Poster.stop(token: token)
            return "The phone's screen reader did not answer, so chats were not opened."
        }
        var sawText = false
        var unreadable = 0
        var names: [String] = []
        for app in apps where ScanRun.going {
            guard await PhoneScreen.open(app) else { continue }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await PhoneScreen.refresh()
            let listed = await PhoneScreen.rows().map(\.text).filter { $0.count > 0 && $0.count <= 80 }
            if listed.isEmpty {
                unreadable += 1
                continue
            }
            sawText = true
            for name in listed where !names.contains(name) { names.append(name) }
        }
        if !sawText {
            await Poster.stop(token: token)
            return "The phone's screen reader did not answer, so chats were not opened."
        }
        await onNames(names)
        let chosen = names.filter { ticked.contains($0) && !isLocked($0) }
        if chosen.isEmpty { return "Tick the chats, then press the button again." }
        var posted = 0
        for app in apps where ScanRun.going {
            guard await PhoneScreen.open(app) else { continue }
            try? await Task.sleep(nanoseconds: 700_000_000)
            if app.app == "outlook" {
                let focused = await readPile(token: token, app: app.app, pile: "Focused", months: months, chosen: chosen)
                unreadable += focused.0
                posted += focused.1
                _ = await PhoneScreen.tap(["Other", "其他"])
                try? await Task.sleep(nanoseconds: 500_000_000)
                let other = await readPile(token: token, app: app.app, pile: "Other", months: months, chosen: chosen)
                unreadable += other.0
                posted += other.1
            } else {
                let result = await readChats(token: token, app: app.app, months: months, chosen: chosen)
                unreadable += result.0
                posted += result.1
            }
        }
        if !ScanRun.going {
            await Poster.stop(token: token)
            return "Stopped"
        }
        if posted == 0 {
            await Poster.stop(token: token)
            return "The phone's screen reader did not answer, so chats were not opened."
        }
        await Poster.finish(token: token, unreadable: unreadable)
        return "The chosen chats were sent."
    }

    private static func readPile(token: String, app: String, pile: String, months: Int, chosen: [String]) async -> (Int, Int) {
        let extra = pile == "Focused" ? "重点" : "其他"
        await PhoneScreen.refresh()
        _ = await PhoneScreen.tap([pile, extra])
        try? await Task.sleep(nanoseconds: 500_000_000)
        return await readChats(token: token, app: app, months: months, chosen: chosen)
    }

    private static func readChats(token: String, app: String, months: Int, chosen: [String]) async -> (Int, Int) {
        var unreadable = 0
        var posted = 0
        await PhoneScreen.refresh()
        for name in chosen where ScanRun.going {
            let visible = await PhoneScreen.rows()
            let rowId = visible.first { $0.text == name }?.key
            let unique = rowId.flatMap { id in visible.filter { $0.key == id }.count == 1 ? id : nil }
            guard await PhoneScreen.tap([name]) else { continue }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await PhoneScreen.refresh()
            if await lockedScreen() {
                _ = await PhoneScreen.tap(["Back", "返回"])
                continue
            }
            let opened = await readOpen(token: token, app: app, chat: name, months: months, rowId: unique)
            unreadable += opened.0
            posted += opened.1
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = await PhoneScreen.tap(["Back", "返回", "Chats"])
            try? await Task.sleep(nanoseconds: 500_000_000)
            await PhoneScreen.refresh()
            _ = await PhoneScreen.longPress(name)
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = await PhoneScreen.tap(unreadLabels)
        }
        return (unreadable, posted)
    }

    private static func readOpen(token: String, app: String, chat: String, months: Int, rowId: String?) async -> (Int, Int) {
        let now = Date().timeIntervalSince1970 * 1000
        let window = DateParser.windowStart(now, months: months)
        var state = ScreenWalk.fresh(now: now)
        var unreadable = 0
        var posted = 0
        var screen = 0
        for _ in 0..<400 {
            if !ScanRun.going { return (unreadable, posted) }
            let rows = await PhoneScreen.rows().filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if rows.isEmpty {
                unreadable += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let oldest = rows.compactMap { DateParser.parse($0.text, now: now) }.min()
            if let oldest, oldest < window {
                if await postLines(token: token, app: app, chat: chat, screen: screen, lines: state.lines + rows.map(\.text), rowId: rowId) { posted += 1 }
                return (unreadable, posted)
            }
            let signature = rows.map(\.text).joined(separator: "\n").prefix(400)
            let step = ScreenWalk.row(state: state, key: String(signature), text: String(signature), loading: false, windowStart: window)
            state = step.0
            if step.1 == "stop" {
                if await postLines(token: token, app: app, chat: chat, screen: screen, lines: state.lines, rowId: rowId) { posted += 1 }
                return (unreadable, posted)
            }
            if step.1 == "read" && state.lines.count >= 8 {
                if await postLines(token: token, app: app, chat: chat, screen: screen, lines: state.lines, rowId: rowId) { posted += 1 }
                screen += 1
                state.lines = []
            }
            _ = await PhoneScreen.scroll()
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        if await postLines(token: token, app: app, chat: chat, screen: screen, lines: state.lines, rowId: rowId) { posted += 1 }
        return (unreadable, posted)
    }

    private static func postLines(token: String, app: String, chat: String, screen: Int, lines: [String], rowId: String?) async -> Bool {
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = kept.first else { return false }
        let key = ChatKey.of(app: app, name: chat, firstLine: first, accessibilityId: rowId ?? "")
        let screenId = "\(key):\(screen)"
        let saved = Bookmark.read()
        Bookmark.save(token: token, runId: saved["runId"] ?? "", months: Int(saved["months"] ?? "") ?? 1, chatKey: key, screenId: screenId)
        return await Poster.screen(token: token, app: app, chatKey: key, screenId: screenId, text: kept.joined(separator: "\n"))
    }

    private static func lockedScreen() async -> Bool {
        let text = await PhoneScreen.rows().map(\.text).joined(separator: " ")
        return text.localizedCaseInsensitiveContains("secret code") || text.contains("锁定") || text.contains("鎖定")
    }

    private static func isLocked(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("lock")
    }
}
