// Profiles for Claude – menu bar app. Shows the active Claude Desktop profile and its
// usage; clicking another profile switches (via ~/.local/bin/claude-profiles).
import Cocoa

let cli = NSHomeDirectory() + "/.local/bin/claude-profiles"

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
            title = p.menuBarTitle
        }
        item.button?.title = switching ? "  switching…" : "  " + title
    }

    /// Two lines per profile: the limits on top, when they reset underneath.
    func limitsTitle(_ p: Profile) -> NSAttributedString {
        let windows = p.usageWindows
        let remaining = windows.map { "\($0.short) \($0.remaining)" }.joined(separator: "   ")
        let resets = windows.compactMap { w in w.reset.map { "\(w.short) \($0)" } }
        let t = NSMutableAttributedString(string: p.label + "   ·   " + remaining,
                                          attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if !resets.isEmpty {
            t.append(NSAttributedString(string: "\nresets  " + resets.joined(separator: " · "),
                                        attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                     .foregroundColor: NSColor.secondaryLabelColor]))
        }
        t.append(NSAttributedString(string: "\n" + p.updated,
                                    attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                 .foregroundColor: NSColor.secondaryLabelColor]))
        return t
    }

    func buildMenu(_ st: Status) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let head = NSMenuItem(title: "Claude Desktop profile · remaining limits", action: nil, keyEquivalent: "")
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
