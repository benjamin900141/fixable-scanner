import Foundation

struct WalkState {
    var now: TimeInterval
    var dateOrder: String
    var lastTop: String
    var idle: Int
    var lines: [String]
}

enum ScreenWalk {
    static func fresh(now: TimeInterval, dateOrder: String = "mdy") -> WalkState {
        WalkState(now: now, dateOrder: dateOrder, lastTop: "", idle: 0, lines: [])
    }

    static func row(state: WalkState, key: String, text: String, loading: Bool, windowStart: TimeInterval) -> (WalkState, String) {
        if loading || text.trimmingCharacters(in: .whitespaces).isEmpty {
            var next = state
            next.idle = 0
            return (next, "wait")
        }
        if let date = DateParser.parse(text, now: state.now, dateOrder: state.dateOrder), date < windowStart {
            return (state, "stop")
        }
        if key == state.lastTop {
            var next = state
            next.idle += 1
            return (next, next.idle >= 2 ? "stop" : "scroll")
        }
        var next = state
        next.lastTop = key
        next.idle = 0
        next.lines.append(text)
        return (next, "read")
    }
}
