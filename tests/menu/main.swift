import AppKit

func profile(_ fh: Int?, _ weekly: Int?, extra: [[String: Any]] = []) -> Profile {
    var windows: [[String: Any]] = []
    if let fh { windows.append(["key": "five_hour", "percentUsed": fh]) }
    if let weekly { windows.append(["key": "weekly", "percentUsed": weekly]) }
    let data = try! JSONSerialization.data(withJSONObject: [
        "n": 1, "label": "Account 1", "active": true, "logged_in": true, "sessions": 0,
        "windows": windows + extra, "age": 720
    ])
    return try! JSONDecoder().decode(Profile.self, from: data)
}

let weekly = profile(14, 96)
assert(weekly.menuBarTitle == "Account 1  ·  7 d 4% left")
assert(weekly.usageWindows.map { $0.remaining } == ["86% left", "4% left"])
assert(weekly.updated == "Updated 12 min ago")
assert(profile(99, 96).menuBarTitle == "Account 1  ·  5 h 1% left")
assert(profile(97, 97).limitingWindow?.key == "weekly")
assert(profile(14, 96, extra: [["key": "weekly_fable", "percentUsed": 100]]).limitingWindow?.key == "weekly")
assert(profile(nil, 96).menuBarTitle.contains("7 d 4% left"))
assert(profile(nil, nil).menuBarTitle == "Account 1  limits unknown")
assert(profile(100, 0).limitingWindow?.remainingPercent == 0)
assert(profile(140, 0).limitingWindow?.remainingPercent == 0)
assert(profile(-10, nil).limitingWindow?.remainingPercent == 100)
let future = (Date().timeIntervalSince1970 + 86400) * 1000
assert(Window(key: "weekly", label: nil, percentUsed: 96, resetsAt: future, estimated: true).reset == nil)
assert(Window(key: "weekly", label: nil, percentUsed: 96, resetsAt: future, estimated: false).reset != nil)
assert(Window(key: "weekly", label: nil, percentUsed: 96, resetsAt: 1, estimated: false).reset == nil)
assert(Window(key: "weekly", label: nil, percentUsed: 96, resetsAt: nil, estimated: nil).reset == nil)

// Icon only: the symbol has to tell the states apart, and a misspelled one would leave no icon at all.
assert(StatusItemLook.idle(Status(active: 1, profiles: [weekly])) ==
       StatusItemLook(symbol: "person.2.circle", text: "Account 1  ·  7 d 4% left"))
assert(StatusItemLook.idle(Status(active: nil, profiles: [])) == .starting)
let looks = [StatusItemLook.starting, .switching, .cliMissing]
assert(Set(looks.map { $0.symbol }).count == looks.count)
for look in looks {
    assert(NSImage(systemSymbolName: look.symbol, accessibilityDescription: nil) != nil, "unknown symbol \(look.symbol)")
}
print("Menu usage tests passed")
