// Profiles for Claude – menu bar app. Shows the active Claude Desktop profile and its
// usage; clicking another profile switches (via ~/.local/bin/claude-profiles).
import Cocoa

let cli = NSHomeDirectory() + "/.local/bin/claude-profiles"

struct Window: Decodable {
    let key: String; let label: String?; let percentUsed: Int?; let resetsAt: Double?

    var short: String {                     // five_hour -> "5 h", weekly_fable -> "Fable"
        switch key {
        case "five_hour": return "5 h"
        case "weekly": return "7 d"
        default:
            if let l = label, l.contains("·") {
                return l.components(separatedBy: "·").last!.trimmingCharacters(in: .whitespaces)
            }
            return label ?? key
        }
    }
    var used: String { percentUsed.map { "\($0) %" } ?? "–" }
    var reset: String? {                    // clock time today, weekday + time later on
        guard let ms = resetsAt else { return nil }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }
}
struct Profile: Decodable {
    let n: Int; let label: String; let active: Bool; let logged_in: Bool
    let sessions: Int; let fh: Int?; let sd: Int?; let windows: [Window]?
}
struct Status: Decodable { let active: Int?; let profiles: [Profile] }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var switching = false
    var lastActive: Int?
    var menuOpen = false

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Profiles for Claude")
            b.imagePosition = .imageLeading
            b.title = " Profiles"
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.refresh() }
    }

    func runCLI(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func refresh() {
        DispatchQueue.global().async {
            let json = self.runCLI(["status", "--json"])
            guard let data = json.data(using: .utf8),
                  let st = try? JSONDecoder().decode(Status.self, from: data) else {
                DispatchQueue.main.async { self.item.button?.title = "  Profiles: CLI missing" }
                return
            }
            DispatchQueue.main.async { self.render(st) }
        }
    }

    func render(_ st: Status) {
        if switching, let a = st.active, a != lastActive { switching = false }
        lastActive = st.active
        if !menuOpen { item.menu = buildMenu(st) }
        var title = "Profiles"
        if let p = st.profiles.first(where: { $0.active }) {
            title = p.label
            if let fh = p.fh, p.logged_in { title += "  \(fh)%" }
            if !p.logged_in { title += "  (sign in)" }
        }
        item.button?.title = switching ? "  switching…" : "  " + title
    }

    /// Two lines per profile: the limits on top, when they reset underneath.
    func limitsTitle(_ p: Profile) -> NSAttributedString {
        var windows = p.windows ?? []
        if windows.isEmpty {        // older CLI without recorded windows
            windows = [Window(key: "five_hour", label: nil, percentUsed: p.fh, resetsAt: nil),
                       Window(key: "weekly", label: nil, percentUsed: p.sd, resetsAt: nil)]
        }
        let used = windows.map { "\($0.short) \($0.used)" }.joined(separator: "   ")
        let resets = windows.compactMap { w in w.reset.map { "\(w.short) \($0)" } }
        let t = NSMutableAttributedString(string: p.label + "   ·   " + used,
                                          attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if !resets.isEmpty {
            t.append(NSAttributedString(string: "\nresets  " + resets.joined(separator: " · "),
                                        attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                     .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return t
    }

    func buildMenu(_ st: Status) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let head = NSMenuItem(title: "Claude Desktop profile", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for p in st.profiles {
            let mi = NSMenuItem(title: p.label, action: #selector(switchTo(_:)), keyEquivalent: p.n <= 9 ? String(p.n) : "")
            if p.logged_in {
                mi.attributedTitle = limitsTitle(p)
            } else {
                mi.title = p.label + "   ·   not signed in yet"
            }
            mi.tag = p.n
            mi.target = self
            mi.state = p.active ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add profile…", action: #selector(addProfile), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let next = NSMenuItem(title: "Next profile", action: #selector(nextSwitch), keyEquivalent: "n")
        next.target = self
        menu.addItem(next)
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Switching relaunches Claude (~10 s); sessions carry over", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        let r = NSMenuItem(title: "Refresh", action: #selector(doRefresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        menu.addItem(NSMenuItem(title: "Quit Profiles for Claude", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; refresh() }

    @objc func switchTo(_ sender: NSMenuItem) {
        if sender.tag == lastActive { return }
        doSwitch([String(sender.tag)])
    }
    @objc func nextSwitch() { doSwitch(["next"]) }
    @objc func addProfile() { doSwitch(["add", "--switch"]) }   // new slot; Claude relaunches signed out
    @objc func doRefresh() { refresh() }

    func doSwitch(_ args: [String]) {
        switching = true
        item.button?.title = "  switching…"
        DispatchQueue.global().async {
            let out = self.runCLI(args)          // the CLI detaches and returns immediately
            if out.contains("already") || out.contains("No other") {
                DispatchQueue.main.async { self.switching = false; self.refresh() }
                return
            }
            for i in 1...30 {                    // wait up to 60 s for the switch to land
                Thread.sleep(forTimeInterval: 2)
                DispatchQueue.main.async { self.refresh() }
                if !self.switching || i == 30 { break }
            }
            DispatchQueue.main.async { self.switching = false; self.refresh() }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
