import AppKit
import SwiftUI

struct BrewAction: Identifiable {
    let command: String
    let title: String
    let detail: String
    let icon: String
    var id: String { command }
    static let all: [BrewAction] = [
        .init(command: "update", title: "Update", detail: "Refresh Homebrew & package definitions", icon: "arrow.triangle.2.circlepath"),
        .init(command: "outdated", title: "Outdated", detail: "Find packages with newer versions", icon: "magnifyingglass"),
        .init(command: "upgrade", title: "Upgrade", detail: "Install available package upgrades", icon: "arrow.up.circle"),
        .init(command: "cleanup", title: "Cleanup", detail: "Remove old versions & stale downloads", icon: "sparkles"),
        .init(command: "autoremove", title: "Autoremove", detail: "Uninstall unneeded dependencies", icon: "shippingbox"),
        .init(command: "doctor", title: "Doctor", detail: "Check configuration & system health", icon: "stethoscope")
    ]
}

@MainActor final class BrewModel: ObservableObject {
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "System" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); applyAppearance() }
    }
    var preferredScheme: ColorScheme? { appearance == "Dark" ? .dark : (appearance == "Light" ? .light : nil) }
    func applyAppearance() {
        NSApp.appearance = appearance == "System" ? nil : NSAppearance(named: appearance == "Dark" ? .darkAqua : .aqua)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSApp.applicationIconImage = BrandImages.icon(dark: dark)
    }
    @Published var updates: [PackageUpdate] = []
    @Published var updateSearch = ""
    @Published var updatesLoaded = false
    @Published var updatesStale = false
    @Published var updatesError: String?
    @Published var updatesChecked: Date?
    @Published var checkingUpdates = false
    @Published var selectedTab = "Maintenance"
    @Published var search = ""
    @Published var packages: [InstalledPackage] = []
    @Published var inventoryLoaded = false
    @Published var inventoryStale = false
    @Published var inventoryError: String?
    @Published var loadingInventory = false
    @Published var uninstallCandidate: InstalledPackage?
    @Published var follow = true
    @Published var output = ""
    @Published var status = "Preparing environment…"
    @Published var busy = false
    @Published var ready = false
    @Published var stopping = false
    @Published var brewPath: String?
    @Published var command = "Console"
    @Published var exitCode: Int32?
    @Published var started: Date?
    @Published var finished: Date?
    @Published var failed = false
    private var environment = ProcessInfo.processInfo.environment
    private var runner: CommandRunner?
    private var activity: NSObjectProtocol?
    private var pending = Data()
    private var outputTimer: Timer?
    private var resolutionID = UUID()
    private var truncated = false
    private let limit = 500_000

    init(prepareOnLaunch: Bool = true) { if prepareOnLaunch { prepare() } }

    func prepare() {
        guard !busy else { return }
        ready = false; busy = true; status = "Preparing environment…"
        let id = UUID(); resolutionID = id
        let process = CommandRunner(); runner = process
        var captured = Data()
        // Login startup files commonly define brew shellenv. No interactive shell or Terminal.app is needed.
        process.run(executable: "/bin/zsh", arguments: ["-l", "-c", "/usr/bin/env -0"], environment: environment) { data in
            if captured.count < 1_000_000 { captured.append(data) }
        } completion: { [weak self] code, _ in
            guard let self = self, self.resolutionID == id else { return }
            var env = ProcessInfo.processInfo.environment
            if code == 0 {
                for entry in captured.split(separator: 0) {
                    let value = String(decoding: entry, as: UTF8.self)
                    if let equal = value.firstIndex(of: "=") {
                        let key = String(value[..<equal])
                        if key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
                            env[key] = String(value[value.index(after: equal)...])
                        }
                    }
                }
            }
            let resolved = BrewEnvironment.resolve(env)
            self.brewPath = resolved.0; self.environment = resolved.1
            self.busy = false; self.ready = resolved.0 != nil; self.runner = nil
            self.status = self.ready ? "Ready" : "Homebrew not found"
            if code != 0 { self.output = "Login environment unavailable; using standard Homebrew paths.\n" }
            if !self.ready { self.output += "Install Homebrew from brew.sh, then choose Retry.\n" }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak process] in
            if self?.resolutionID == id && self?.ready == false && self?.busy == true { process?.cancel() }
        }
    }

    func run(_ action: BrewAction) {
        execute(arguments: [action.command]) { [weak self] code, cancelled in
            guard let self = self else { return }
            self.inventoryStale = true; self.updatesStale = true
        }
    }

    private func execute(arguments: [String], standardOutputFile: URL? = nil, preserveOutput: Bool = false,
                         completion: @escaping (Int32, Bool) -> Void = { _, _ in }) {
        guard ready, !busy, let path = brewPath else { return }
        uninstallCandidate = nil
        busy = true; stopping = false; failed = false; exitCode = nil
        started = Date(); finished = nil; command = "brew " + arguments.joined(separator: " "); status = "Running"
        pending.removeAll(); truncated = false
        let heading = "[\(Date().formatted(date: .omitted, time: .standard))] $ \(command)\n"
        if preserveOutput { append("\n" + heading) } else { output = heading }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Homebrew maintenance")
        let process = CommandRunner(); runner = process
        outputTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        // Interactive commands run under a PTY so brew emits its live progress bar. JSON captures
        // (standardOutputFile set) stay on a plain pipe for clean, parseable output.
        process.run(executable: path, arguments: arguments, environment: environment,
                    standardOutputFile: standardOutputFile, usePTY: standardOutputFile == nil) { [weak self] data in
            self?.pending.append(data)
        } completion: { [weak self] code, cancelled in
            guard let self = self else { return }
            self.flush(final: true)
            self.outputTimer?.invalidate(); self.outputTimer = nil
            self.exitCode = code; self.finished = Date(); self.busy = false; self.stopping = false
            self.failed = code != 0 && !cancelled
            self.status = cancelled ? "Cancelled" : (code == 0 ? "Succeeded" : "Needs attention")
            while self.output.last == "\n" || self.output.last == "\r" { self.output.removeLast() }
            self.append("\n[\(Date().formatted(date: .omitted, time: .standard))] \(self.status) · Exit \(code)\n")
            if cancelled { self.append("Completed changes are not rolled back. Run Doctor to check Homebrew.\n") }
            self.runner = nil
            if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity) }; self.activity = nil
            completion(code, cancelled)
        }
    }


    var filteredPackages: [InstalledPackage] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return packages.filter { query.isEmpty || "\($0.name) \($0.token) \($0.detail) \($0.kind)".localizedCaseInsensitiveContains(query) }
    }

    func loadInstalledIfNeeded() {
        if !inventoryLoaded && !busy && ready { refreshInstalled() }
    }

    func refreshInstalled() {
        guard ready, !busy else { return }
        loadingInventory = true; inventoryError = nil
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BrewBar-\(UUID().uuidString).json")
        execute(arguments: ["info", "--json=v2", "--installed"], standardOutputFile: file) { [weak self] code, cancelled in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let self = self else { return }
            self.loadingInventory = false
            guard code == 0 && !cancelled else {
                self.inventoryError = cancelled ? "Refresh cancelled. Try again when ready." : "Could not read installed packages. See the console, then retry."
                self.inventoryStale = true
                return
            }
            do {
                self.packages = try InstalledPackage.parse(Data(contentsOf: file))
                self.inventoryLoaded = true; self.inventoryStale = false
                self.append("Loaded \(self.packages.count) installed Homebrew packages.\n")
            } catch {
                self.failed = true; self.status = "Could not read packages"
                self.inventoryError = "Homebrew returned an unreadable package list. Try Refresh."
                self.inventoryStale = true
                self.append("Could not decode package list: \(error.localizedDescription)\n")
            }
        }
    }

    func uninstall(_ package: InstalledPackage) {
        guard !busy, ready, packages.contains(where: { $0.id == package.id }), package.canUninstall else { return }
        uninstallCandidate = nil
        execute(arguments: package.uninstallArguments) { [weak self] _, _ in
            // Even a failed or cancelled uninstall can make partial changes. Reload from Homebrew.
            guard let self = self else { return }
            self.inventoryStale = true; self.updatesStale = true
            // Keep uninstall output visible. The list explicitly asks for a refresh rather than replacing its log.
            self.packages.removeAll { $0.id == package.id && self.exitCode == 0 && self.status == "Succeeded" }
        }
    }


    func loadUpdatesIfNeeded() {
        if !updatesLoaded && !busy && ready { checkUpdates() }
    }

    func checkUpdates(preserveOutput: Bool = false) {
        guard ready, !busy else { return }
        checkingUpdates = true; updatesError = nil
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BrewBar-updates-\(UUID().uuidString).json")
        execute(arguments: ["outdated", "--json=v2"], standardOutputFile: file, preserveOutput: preserveOutput) { [weak self] code, cancelled in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let self = self else { return }
            self.checkingUpdates = false
            guard code == 0 && !cancelled else {
                self.updatesError = cancelled ? "Update check cancelled." : "Update check failed. See console and retry."
                self.updatesStale = true; return
            }
            do {
                self.updates = try PackageUpdate.parse(Data(contentsOf: file))
                self.updatesLoaded = true; self.updatesStale = false; self.updatesChecked = Date()
                self.append("\(self.updates.count) available updates in current definitions.\n")
            } catch {
                self.updatesError = "Could not read Homebrew update data. Retry the check."
                self.updatesStale = true; self.failed = true; self.status = "Update data error"
            }
        }
    }

    func refreshDefinitions() {
        guard !busy, ready else { return }
        updatesStale = true
        execute(arguments: ["update"]) { [weak self] code, cancelled in
            guard let self = self else { return }
            if code == 0 && !cancelled { self.checkUpdates(preserveOutput: true) }
            else { self.updatesError = "Definitions were not refreshed. See console and retry." }
        }
    }

    func upgrade(_ package: PackageUpdate) {
        guard ready, !busy, !updatesStale, !package.pinned, package.valid,
              updates.contains(where: { $0.id == package.id }) else { return }
        execute(arguments: package.arguments) { [weak self] code, cancelled in
            guard let self = self else { return }
            self.inventoryStale = true; self.updatesStale = true
        }
    }

    func upgradeAll() {
        guard !busy, ready, !updatesStale, updates.contains(where: { !$0.pinned }) else { return }
        execute(arguments: ["upgrade"]) { [weak self] code, cancelled in
            guard let self = self else { return }
            self.inventoryStale = true; self.updatesStale = true
        }
    }

    private func flush(final: Bool = false) {
        guard !pending.isEmpty else { return }
        // Keep incomplete UTF-8 sequences until the following read.
        var count = pending.count
        if !final {
            let bytes = Array(pending.suffix(4))
            for offset in 1...min(4, bytes.count) {
                let byte = bytes[bytes.count - offset]
                if byte & 0xc0 != 0x80 {
                    let required = byte < 0x80 ? 1 : (byte & 0xe0 == 0xc0 ? 2 : (byte & 0xf0 == 0xe0 ? 3 : 4))
                    if required > offset { count -= offset }; break
                }
            }
        }
        guard count > 0 else { return }
        var text = String(decoding: pending.prefix(count), as: UTF8.self)
        pending.removeFirst(count)
        // Strip ANSI control sequences (cursor moves, colours) first, then honour carriage returns
        // so brew's progress bar rewrites a single line in place instead of flooding the console.
        text = text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        append(text)
    }
    /// Appends `text` to `output`, treating a bare carriage return as "move to the start of the
    /// current line and overwrite it". This keeps live progress bars on one line and leaves the
    /// stored `output` clean for the Console view and the Copy button.
    private func append(_ text: String) {
        for character in text {
            if character == "\r" {
                // Erase back to the start of the current line (after the last newline).
                if let newline = output.lastIndex(of: "\n") {
                    output.removeSubrange(output.index(after: newline)..<output.endIndex)
                } else {
                    output.removeAll(keepingCapacity: true)
                }
            } else {
                output.append(character)
            }
        }
        if output.utf8.count > limit {
            output = "[Earlier output trimmed; showing recent output]\n" + String(output.suffix(limit / 2))
            truncated = true
        }
    }
    func stop() { guard busy else { return }; stopping = true; status = "Stopping…"; runner?.cancel() }
    func clear() { output = ""; pending.removeAll(); truncated = false }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) }
}
