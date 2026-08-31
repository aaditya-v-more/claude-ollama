// Menu bar item for "Claude (Ollama).app".
//
// The bundle used to be a shell script that started Claude and exited. It now
// stays resident as an accessory app so there is somewhere to show what the
// pacing proxy is doing — which port it settled on, how many requests are in
// flight, how often the gateway is pushing back. All of that comes from
// `claude-ollama status --json`, so the launcher stays the single place that
// knows how any of it works.
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

struct Status: Decodable {
    let proxy: Proxy?
    let claudeRunning: Bool
    let log: String
    let config: String
}

enum Launcher {
    /// The `claude-ollama` this bundle belongs to. Checked in the order a
    /// source checkout, a cask and an Intel prefix would each put it.
    static let path: String? = {
        let fm = FileManager.default
        let beside = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/claude-ollama").path
        let candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_OLLAMA_BIN"],
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

// MARK: - The item itself

final class Controller: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var status: Status?
    private var sawClaude = false
    private var missingSince: Date?
    private let launchedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.autoenablesItems = false
        item.menu = menu
        draw()

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
        let alert = NSAlert()
        alert.messageText = "Could not start Claude on the Ollama gateway."
        alert.informativeText = output.isEmpty ? "The launcher exited without a message." : output
        alert.alertStyle = .warning
        alert.runModal()
        NSApp.terminate(nil)
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
            addAction("Open Settings File", #selector(openConfig))
            addAction("Quit", #selector(quit))
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
        addAction("Open Settings File", #selector(openConfig))
        menu.addItem(.separator())
        addAction("Restart Proxy", #selector(restartProxy))
        menu.addItem(.separator())
        addAction("Quit", #selector(quit))
    }

    private func uptime(since epoch: Double) -> String {
        let seconds = Int(Date().timeIntervalSince1970 - epoch)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    private func add(_ title: String, indented: Bool = false) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        if indented { entry.indentationLevel = 1 }
        menu.addItem(entry)
    }

    private func addAction(_ title: String, _ selector: Selector) {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = true
        menu.addItem(entry)
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

    @objc private func restartProxy() {
        DispatchQueue.global(qos: .userInitiated).async {
            Launcher.run(["restart-proxy"])
            DispatchQueue.main.async { self.poll() }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
