// Menu bar item for "Claude (Ollama).app".
//
// The bundle used to be a shell script that started Claude and exited. It now
// stays resident as an accessory app so there is somewhere to show what the
// pacing proxy is doing — which port it settled on, how many requests are in
// flight, how often the gateway is pushing back. All of that comes from
// `claude-ollama status --json`, so the launcher stays the single place that
// knows how any of it works. The settings hang off the same menu, and an edited
// value goes back out through `claude-ollama config --set` — which names exist,
// what they default to and what overrides what are all still the launcher's to
// decide.
//
// It quits itself once Claude Desktop quits, the same rule the proxy follows.

import AppKit
import Foundation

// MARK: - Talking to the launcher

struct Proxy: Decodable {
    let port: Int
    let upstream: String
    let limit: Int
    let attempts: Int
    let inflight: Int
    let queued: Int
    let served: Int
    let retries: Int
    let giveups: Int
    let warm: Bool
    let started: Double
    let lastRetry: LastRetry?
    let models: [Model]

    struct LastRetry: Decodable {
        let status: Int
        let at: Double
        let path: String
    }

    struct Model: Decodable {
        let model: String
        let context: Int?
    }

    enum CodingKeys: String, CodingKey {
        case port, upstream, limit, attempts, inflight, queued, served
        case retries, giveups, warm, started, models
        case lastRetry = "last_retry"
    }
}

/// One tunable, as the launcher reports it: the effective value, whether that
/// came from the environment, the settings file or the built-in default, and
/// which half of the menu it belongs in.
struct Setting: Decodable {
    let name: String
    let value: String
    let source: String
    let group: String
}

struct Status: Decodable {
    let proxy: Proxy?
    let claudeRunning: Bool
    let log: String
    let config: String
    /// Optional so that an older `claude-ollama` still on the PATH — one that
    /// reports no settings — costs the menu its settings rather than every
    /// other thing on it.
    let settings: [Setting]?
}

/// The addresses this app sends people to.
///
/// The tip jar is a different account from the GitHub one and is spelled
/// differently: GitHub Sponsors cannot pay into an Indian account, so the money
/// goes through Ko-fi, whose handle carries no hyphens. Neither name derives
/// from the other, and `.github/FUNDING.yml` and the README carry the same two
/// spellings. A build already installed keeps whatever it was compiled with, so
/// a rename that touched only one of them would leave a dead link in every copy
/// out in the world.
enum Links {
    static let owner = "aaditya-v-more"
    static let kofiAccount = "aadityavmore"

    static let source = URL(string: "https://github.com/\(owner)/claude-ollama")!
    static let support = URL(string: "https://ko-fi.com/\(kofiAccount)")!
}

enum Launcher {
    /// The `claude-ollama` this bundle belongs to. Its own copy first — the
    /// launcher and the proxy ship in Contents/Resources/bin, which is what
    /// lets one update replace the app and the commands together — then the
    /// places a source checkout, a cask and an Intel prefix would each put it.
    static let path: String? = {
        let fm = FileManager.default
        let inside = Bundle.main.resourceURL?
            .appendingPathComponent("bin/claude-ollama").path
        let beside = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/claude-ollama").path
        let candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_OLLAMA_BIN"],
            inside,
            beside,
            "/opt/homebrew/bin/claude-ollama",
            "/usr/local/bin/claude-ollama",
        ]
        return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0) }
    }()

    @discardableResult
    static func run(_ arguments: [String]) -> (code: Int32, output: String) {
        guard let path = path else { return (127, "claude-ollama not found") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (127, "could not run \(path): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

#if canImport(Sparkle)
import Sparkle

/// In-app updates, through Sparkle, arriving the way this app already behaves.
///
/// A new version is found on a schedule and downloaded without anyone being
/// asked, and then it waits. Sparkle installs a staged update when the app
/// terminates, and this app terminates when Claude does — so the update lands
/// in the gap between one session and the next, and the next launch is the new
/// version. Nothing is swapped underneath a running Claude, nothing relaunches,
/// nothing asks. claude-graft installs the moment it has one because it is
/// meant to sit in the menu bar for weeks; this one is only ever up for as long
/// as Claude is, so waiting costs nothing and the quiet is worth having.
///
/// What makes it enough to replace the bundle is that the bundle is the whole
/// install: the launcher and the proxy are inside it, and the commands on the
/// PATH are symlinks into it.
final class Updater: NSObject, SPUUpdaterDelegate {
    /// The version downloaded and waiting, for the menu to mention. Set once
    /// and never cleared: by the time it is set, the update is going in.
    private(set) var staged: String?
    /// Redraws the menu when that changes.
    var onChange: (() -> Void)?

    /// Checked this often, and at launch when that long has passed since the
    /// last one — which, for an app that lives and dies with a Claude session,
    /// is the check that does most of the work.
    static let checkInterval: TimeInterval = 60 * 60

    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                     updaterDelegate: self,
                                                     userDriverDelegate: nil)
        self.controller = controller
        // Set every launch rather than seeded once: this is how the app
        // behaves, not a default someone was offered and might have changed.
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        controller.updater.updateCheckInterval = Self.checkInterval
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// `checkForUpdatesInBackground` rather than `checkForUpdates`, which is
    /// the difference between an update installing and an update asking. The
    /// interactive one puts up Sparkle's own panel and waits to be told to
    /// install and relaunch — a strange thing to do from a menu whose other
    /// half is already installing updates quietly.
    func check() { controller?.updater.checkForUpdatesInBackground() }

    // MARK: SPUUpdaterDelegate

    /// Returning true takes the update off Sparkle's scheduler and out of its
    /// UI, and never calling the handler is what leaves it for the quit —
    /// "Sparkle will always attempt to install the update when the app
    /// terminates", as its own header puts it.
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstall: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async {
            self.staged = item.displayVersionString
            self.onChange?()
        }
        return true
    }

    /// The item leaves when Claude leaves. Coming back on its own after an
    /// update installed would leave a menu bar item sitting beside no Claude
    /// at all, which is the one state this app is written never to be in.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }
}
#endif

// MARK: - The item itself

final class Controller: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var status: Status?
    private var sawClaude = false
    private var missingSince: Date?
    private let launchedAt = Date()
#if canImport(Sparkle)
    private let updater = Updater()
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.autoenablesItems = false
        item.menu = menu
        draw()

#if canImport(Sparkle)
        updater.onChange = { [weak self] in self?.draw() }
        updater.start()
#endif

        // Start Claude before the first poll, on a background queue so the menu
        // bar item appears immediately rather than after the proxy warms up.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Launcher.run(["run"])
            if result.code != 0 {
                DispatchQueue.main.async { self.report(result.output) }
            }
            DispatchQueue.main.async { self.poll() }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func report(_ output: String) {
        warn("Could not start Claude on the Ollama gateway.", output)
        NSApp.terminate(nil)
    }

    /// An accessory app has no windows and never becomes active on its own, so
    /// without the activate the dialog opens behind whatever is in front.
    private func warn(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail.isEmpty ? "The launcher exited without a message." : detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async {
            let result = Launcher.run(["status", "--json"])
            let decoded = result.output.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(Status.self, from: $0)
            }
            DispatchQueue.main.async {
                self.status = decoded
                self.checkForExit()
                self.draw()
            }
        }
    }

    /// Leave when Claude does. Confirmed over a few seconds so that quitting and
    /// relaunching straight away does not take the menu item down with it, and
    /// only after Claude has been seen at least once — it takes a moment to
    /// appear in the process table on a cold start.
    private func checkForExit() {
        guard let status = status else { return }
        if status.claudeRunning {
            sawClaude = true
            missingSince = nil
            return
        }
        guard sawClaude || Date().timeIntervalSince(launchedAt) > 90 else { return }
        let since = missingSince ?? Date()
        missingSince = since
        if Date().timeIntervalSince(since) > 6 { NSApp.terminate(nil) }
    }

    // MARK: Drawing

    private func draw() {
        let proxy = status?.proxy
        let symbol = proxy == nil ? "bolt.horizontal.circle" : "bolt.horizontal.circle.fill"
        item.button?.image = NSImage(systemSymbolName: symbol,
                                     accessibilityDescription: "Claude (Ollama)")
        item.button?.imagePosition = .imageLeading
        if let proxy = proxy, proxy.inflight > 0 {
            item.button?.title = " \(proxy.inflight)"
        } else {
            item.button?.title = ""
        }

        menu.removeAllItems()
        guard let proxy = proxy else {
            add("Pacing proxy not running")
            menu.addItem(.separator())
            addSettings()
            addFooter()
            return
        }

        add("Proxy · 127.0.0.1:\(proxy.port)")
        add("Upstream · \(proxy.upstream)", indented: true)
        add("\(proxy.inflight) in flight of \(proxy.limit) · \(proxy.queued) queued",
            indented: true)
        add("\(proxy.served) served · \(proxy.retries) retried · \(proxy.giveups) gave up",
            indented: true)

        if proxy.warm {
            let big = proxy.models.filter { ($0.context ?? 0) >= 1_000_000 }.count
            add("\(big) of \(proxy.models.count) models at 1M", indented: true)
        } else {
            add("Reading model context lengths…", indented: true)
        }

        if let last = proxy.lastRetry {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let when = formatter.string(from: Date(timeIntervalSince1970: last.at))
            add("Last pushback · \(last.status) at \(when)", indented: true)
        }

        add("Up \(uptime(since: proxy.started))", indented: true)

        menu.addItem(.separator())
        addAction("Copy Endpoint", #selector(copyEndpoint))
        addAction("Open Proxy Log", #selector(openLog))
        addSettings()
        menu.addItem(.separator())
        addAction("Restart Proxy", #selector(restartProxy))
        addFooter()
    }

    /// Every tunable, editable in place, over a note saying when a change will
    /// count for anything.
    ///
    /// The note is about the next launch rather than the next proxy restart
    /// because that is the one thing true of all of them. Restart Proxy does
    /// pick most of the proxy's own settings up sooner — but not PACE_PORT: a
    /// running Claude read its endpoint once at startup and would be left
    /// talking to the port the proxy has just left.
    private func addSettings() {
        let settings = status?.settings ?? []
        guard !settings.isEmpty else {
            // No settings to draw means an older launcher answering; the file
            // is still there to be opened by hand.
            addAction("Open Settings File", #selector(openConfig))
            return
        }

        let entry = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        entry.submenu = submenu
        menu.addItem(entry)

        add("Changes apply the next time Claude starts", to: submenu)
        for (group, heading) in [("claude", "Claude Desktop"), ("proxy", "Pacing proxy")] {
            let members = settings.filter { $0.group == group }
            guard !members.isEmpty else { continue }
            submenu.addItem(.separator())
            add(heading, to: submenu)
            for setting in members {
                let row = NSMenuItem(title: "\(setting.name) · \(display(setting.value))",
                                     action: #selector(editSetting(_:)), keyEquivalent: "")
                row.target = self
                row.isEnabled = true
                row.indentationLevel = 1
                row.representedObject = setting
                submenu.addItem(row)
            }
        }
        submenu.addItem(.separator())
        addAction("Open Settings File", #selector(openConfig), to: submenu)
    }

    /// A value as the menu shows it, which is not always as it is: the home
    /// directory is abbreviated and a long one is cut short. The editor and the
    /// file always carry the real thing — the settings reader does no tilde
    /// expansion, so a `~` written into it would stay a `~`.
    private func display(_ value: String) -> String {
        let short = (value as NSString).abbreviatingWithTildeInPath
        return short.count > 40 ? short.prefix(39) + "…" : short
    }

    /// Where it came from and who pays for it. Free, and staying that way, so
    /// the tip jar is the only thing asked of anyone — once, at the bottom of a
    /// menu they had to open on purpose.
    private func addFooter() {
        menu.addItem(.separator())
        addAction("Support", #selector(openSupport), symbol: "heart")
        addAction("Source", #selector(openSource),
                  symbol: "chevron.left.forwardslash.chevron.right")
        menu.addItem(.separator())
        addUpdates()
        addAction("Quit", #selector(quit))
    }

    /// What version this is, and what is going to happen about the next one.
    ///
    /// The version is worth a line of its own precisely because updates are
    /// silent: an app that replaces itself without asking should at least say
    /// what it is now. A staged update is stated rather than offered, because
    /// there is nothing left to decide — it goes in when Claude quits.
    private func addUpdates() {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        add("Claude (Ollama) \(version ?? "—")")
#if canImport(Sparkle)
        if let staged = updater.staged {
            add("Version \(staged) installs when Claude quits", indented: true)
        } else {
            let entry = NSMenuItem(title: "Check for Updates",
                                   action: #selector(checkForUpdates), keyEquivalent: "")
            entry.target = self
            // Dimmed rather than missing while a check is already running, so
            // the line does not come and go under the pointer.
            entry.isEnabled = updater.canCheck
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
#endif
        menu.addItem(.separator())
    }

    private func uptime(since epoch: Double) -> String {
        let seconds = Int(Date().timeIntervalSince1970 - epoch)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    // `to` defaults to the menu itself; the settings submenu is the only thing
    // that passes anything else.
    private func add(_ title: String, indented: Bool = false, to target: NSMenu? = nil) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        if indented { entry.indentationLevel = 1 }
        (target ?? menu).addItem(entry)
    }

    private func addAction(_ title: String, _ selector: Selector, symbol: String? = nil,
                           to target: NSMenu? = nil) {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = true
        if let symbol = symbol {
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        (target ?? menu).addItem(entry)
    }

    // MARK: Actions

    @objc private func copyEndpoint() {
        guard let port = status?.proxy?.port else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(port)", forType: .string)
    }

    @objc private func openLog() {
        guard let log = status?.log else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: log))
    }

    @objc private func openConfig() {
        guard let config = status?.config else { return }
        if !FileManager.default.fileExists(atPath: config) {
            Launcher.run(["config", "--init"])
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: config))
    }

    /// One setting, in a dialog. Saving hands the value to the launcher rather
    /// than writing the file here, so a name that does not exist, a value the
    /// file cannot hold, and the ordering inside it stay one implementation.
    @objc private func editSetting(_ sender: NSMenuItem) {
        guard let setting = sender.representedObject as? Setting else { return }

        let alert = NSAlert()
        alert.messageText = setting.name
        alert.informativeText = explain(setting)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = setting.value
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // Nothing to go back to when the value is already the built-in one.
        if setting.source != "default" { alert.addButton(withTitle: "Use Default") }
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(setting.name, field.stringValue)
        case .alertThirdButtonReturn: save(setting.name, "")
        default: break
        }
    }

    private func explain(_ setting: Setting) -> String {
        let origin: String
        switch setting.source {
        case "environment":
            origin = "\(setting.value) — from the environment, which beats the "
                   + "settings file. Saving writes the file, so it counts once "
                   + "that variable is gone."
        case "file":
            origin = "\(setting.value) — from the settings file."
        default:
            origin = "\(setting.value) — the built-in default."
        }
        return origin + "\n\nSaved settings are applied the next time Claude starts."
    }

    /// An empty value takes the line out of the file again, which is what the
    /// Use Default button asks for.
    private func save(_ name: String, _ value: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Launcher.run(["config", "--set", "\(name)=\(value)"])
            DispatchQueue.main.async {
                if result.code != 0 { self.warn("Could not save \(name).", result.output) }
                self.poll()
            }
        }
    }

    @objc private func restartProxy() {
        DispatchQueue.global(qos: .userInitiated).async {
            Launcher.run(["restart-proxy"])
            DispatchQueue.main.async { self.poll() }
        }
    }

#if canImport(Sparkle)
    @objc private func checkForUpdates() {
        updater.check()
        // The check runs on its own; redrawing now is what dims the line.
        draw()
    }
#endif

    @objc private func openSupport() { NSWorkspace.shared.open(Links.support) }

    @objc private func openSource() { NSWorkspace.shared.open(Links.source) }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
