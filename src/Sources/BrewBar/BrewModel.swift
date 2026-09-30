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
    var appearanceMode: AppearanceMode { AppearanceMode(appearance) }
    /// The color scheme forced on the SwiftUI hierarchy. Papery modes still force their
    /// underlying light/dark so native controls stay legible; the Theme overrides the visuals.
    var preferredScheme: ColorScheme? { appearanceMode.underlyingScheme }
    func applyAppearance() {
        let mode = appearanceMode
        // `NSApp` is an implicitly-unwrapped optional and is nil before NSApplication is set up
        // (e.g. in headless unit tests). Guard so the model stays usable without a running app.
        guard let app = NSApplication.shared as NSApplication? else { return }
        // System uses the OS appearance; every other mode (including Papery) pins aqua/darkAqua.
        switch mode.underlyingScheme {
        case .some(.dark): app.appearance = NSAppearance(named: .darkAqua)
        case .some(.light): app.appearance = NSAppearance(named: .aqua)
        default: app.appearance = nil
        }
        let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Papery uses its own paper icon tone: dark paper -> dark icon, cream -> light icon.
        app.applicationIconImage = BrandImages.icon(dark: mode.isPapery ? mode.isDarkPaper : dark)
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
    // Search & Install (a mode toggle inside the Installed tab).
    @Published var installedTabMode = "Installed"     // "Installed" | "Search"
    @Published var searchQuery = ""
    @Published var searchResults: [SearchResult] = []
    @Published var searching = false
    @Published var searchError: String?
    @Published var searchPerformed = false
    @Published var installCandidate: SearchResult?
    // Per-package info popover (Feature 2). `infoTarget` is the id (kind:token) whose popover is
    // open; `packageInfo` holds the fetched detail once ready; `infoLoading` gates a spinner;
    // `infoError` shows a short message when the fetch fails.
    @Published var infoTarget: String?
    @Published var packageInfo: PackageInfo?
    @Published var infoLoading = false
    @Published var infoError: String?
    // Menu-bar update badge (Feature 1). Count of outdated packages from the most recent check
    // (manual or the silent background check). Drives the menu-bar label + glyph dot.
    @Published var updateCount = 0
    // Brewfile restore confirmation (Feature 4). Holds the chosen Brewfile URL awaiting the user's
    // confirmation before `brew bundle install` runs (mirrors the install/uninstall confirm pattern).
    @Published var brewfileRestoreCandidate: URL?
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
    /// True while the running command is blocked on an interactive `[y/n]` prompt (e.g. brew's
    /// upgrade/install confirmation). The console then offers Yes/No buttons wired to `answer(_:)`.
    @Published var awaitingInput = false
    /// The prompt line brew printed (shown next to the Yes/No buttons).
    @Published var promptText = ""
    /// Live download progress for the console's pinned block. Homebrew's parallel download queue
    /// reports several packages at once, so this is a collection keyed by package name (insertion-
    /// ordered) rather than a single slot — each entry pairs the right name with the right bytes,
    /// so the block can't show a mismatched name/bytes. Populated from parsing brew's parallel-queue
    /// `Downloading X/Y` lines; entries stay (marked done at 100%) until every download finishes,
    /// then the whole block commits to the log and clears. Empty when nothing is downloading.
    @Published private(set) var downloads: [DownloadEntry] = []
    /// Insertion order for `downloads` so the pinned block keeps a stable row order.
    private var downloadOrder: [String] = []
    /// A single-download fallback (the percentage-only bar path: `==> Downloading <url>` then
    /// `####  NN.N%`), used when brew isn't reporting named byte counters. Rendered as one entry in
    /// the same block. Nil when the parallel byte-counter path is driving the block.
    private var singleDownloadName: String?
    /// A recoverable failure BrewBar can offer to fix with one click (currently: a resumable-download
    /// dead-end where a stale partial file in brew's cache can't be resumed). Set when a command
    /// fails with the matching signature; cleared when a new command runs, on Stop, or on Clear.
    @Published var recovery: RecoveryHint?
    /// The arguments of the most recent user-run maintenance command, kept so the recovery flow can
    /// re-run the exact same command after clearing the stale download cache.
    private var lastArguments: [String] = []
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
        awaitingInput = false; promptText = ""; clearDownload(); recovery = nil
        lastArguments = arguments
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
            self.awaitingInput = false; self.promptText = ""; self.clearDownload()
            self.failed = code != 0 && !cancelled
            self.status = cancelled ? "Cancelled" : (code == 0 ? "Succeeded" : "Needs attention")
            // Offer a one-click fix when the failure is a resumable-download dead-end (curl-56 /
            // "Cannot resume"). Only for a real (non-cancelled) failure of a retryable command.
            if self.failed, let hint = RecoveryHintDetector.detect(in: self.output) { self.recovery = hint }
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

    /// Run `brew search <query>`, then enrich the candidate tokens via `brew info --json=v2` so each
    /// result shows a description, version, kind, and whether it is already installed. Two chained
    /// commands: the info call is issued from the search completion (busy is clear again by then).
    private let searchResultLimit = 40
    func searchPackages(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !busy, query.count >= 2,
              query.range(of: "^[A-Za-z0-9][A-Za-z0-9@+._/ -]*$", options: .regularExpression) != nil else {
            if query.count < 2 { searchError = "Type at least two characters to search." }
            return
        }
        searching = true; searchError = nil; searchResults = []; searchPerformed = true
        // Homebrew matches tokens (never spaces/capitals), so a multi-word human query would fall
        // through to a fuzzy match and return unrelated packages. Search on the single most
        // distinctive word, then filter the enriched results by the full query (see enrich).
        let searchTerm = SearchResult.distinctiveTerm(query) ?? query
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BrewBar-search-\(UUID().uuidString).txt")
        execute(arguments: ["search", searchTerm], standardOutputFile: file) { [weak self] code, cancelled in
            guard let self = self else { return }
            defer { try? FileManager.default.removeItem(at: file) }
            guard code == 0 && !cancelled else {
                self.searching = false
                self.searchError = cancelled ? "Search cancelled." : "Search failed. See the console and retry."
                return
            }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let tokens = Array(SearchResult.searchTokens(text).prefix(self.searchResultLimit))
            guard !tokens.isEmpty else {
                self.searching = false
                self.searchError = "No formula or cask found for “\(query)”."
                return
            }
            self.enrich(tokens: tokens, query: query)
        }
    }

    /// Second stage: `brew info --json=v2 <tokens>` → rich SearchResults.
    private func enrich(tokens: [String], query: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BrewBar-info-\(UUID().uuidString).json")
        execute(arguments: ["info", "--json=v2"] + tokens, standardOutputFile: file, preserveOutput: true) { [weak self] code, cancelled in
            guard let self = self else { return }
            defer { try? FileManager.default.removeItem(at: file) }
            self.searching = false
            guard code == 0 && !cancelled else {
                self.searchError = cancelled ? "Search cancelled." : "Could not read package details. See the console and retry."
                return
            }
            do {
                let all = try SearchResult.parse(Data(contentsOf: file))
                // Filter by the full original query so multi-word searches ("Tinycast Beta") keep only
                // packages whose token or name contains every word. Single-word queries keep matches
                // whose token/name contains the word — mirroring brew's own substring behaviour.
                let filtered = all.filter { $0.matches(query: query) }
                // Never show an empty list when brew did return candidates: if the client filter is
                // too strict (e.g. the display name differs from the token), fall back to all results.
                self.searchResults = filtered.isEmpty ? all : filtered
                if self.searchResults.isEmpty { self.searchError = "No installable formula or cask found for “\(query)”." }
                self.append("Found \(self.searchResults.count) installable packages for “\(query)”.\n")
            } catch {
                self.searchError = "Homebrew returned unreadable search details. Try again."
            }
        }
    }

    func install(_ result: SearchResult) {
        guard !busy, ready, result.valid, !result.installed else { return }
        installCandidate = nil
        execute(arguments: result.installArguments) { [weak self] code, cancelled in
            guard let self = self else { return }
            self.inventoryStale = true; self.updatesStale = true
            if code == 0 && !cancelled {
                // Reflect the new state in the results list immediately…
                if let idx = self.searchResults.firstIndex(where: { $0.id == result.id }) {
                    let r = self.searchResults[idx]
                    self.searchResults[idx] = SearchResult(token: r.token, name: r.name, detail: r.detail,
                                                           version: r.version, kind: r.kind, installed: true)
                }
                // …and auto-refresh the installed inventory so the Installed list is accurate.
                self.refreshInstalled()
            }
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
                self.updateCount = self.updates.count
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
            self.inventoryStale = true
            if code == 0 && !cancelled {
                // The package is no longer outdated: drop its row and re-check in the background so
                // the remaining rows stay actionable (no manual "Check" needed after each upgrade).
                self.updates.removeAll { $0.id == package.id }
                self.checkUpdates(preserveOutput: true)
            } else {
                // A failed/cancelled upgrade may have changed things; ask for a re-check before more.
                self.updatesStale = true
            }
        }
    }

    func upgradeAll() {
        guard !busy, ready, !updatesStale, updates.contains(where: { !$0.pinned }) else { return }
        execute(arguments: ["upgrade"]) { [weak self] code, cancelled in
            guard let self = self else { return }
            self.inventoryStale = true
            // Upgrade All targets everything; re-check afterwards to reflect the new state.
            if code == 0 && !cancelled { self.checkUpdates(preserveOutput: true) }
            else { self.updatesStale = true }
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
        // Homebrew's parallel download queue redraws its status line each frame by moving the cursor
        // to column 0 with a CHA sequence (`ESC[<n>G`, typically `ESC[0G`) rather than a bare CR.
        // Translate that to a carriage return first so `append` rewrites the line in place (the same
        // way it handles the single-download bar). Then strip the remaining ANSI control sequences
        // (colours, cursor show/hide, synchronized-output `?2026h/l`, erase-line `[K`) and honour CRs
        // so brew's progress bar updates one line instead of flooding the console.
        text = text.replacingOccurrences(of: "\u{001B}\\[[0-9]*G", with: "\r", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        append(text)
        detectPrompt()
        detectDownload(in: text)
    }

    /// Recognise brew's interactive confirmation (`ohai "Do you want to proceed with the … ? [y/n]"`)
    /// so the console can offer Yes/No. brew only prompts when both stdin and stdout are a TTY, which
    /// is exactly the PTY path; JSON/file captures (search, info, outdated) never prompt.
    ///
    /// This is *edge-triggered*: we arm only when the **current last non-empty line** is itself the
    /// prompt. As soon as brew echoes our answer or prints its next line (Fetching/Downloading…), the
    /// last line is no longer the prompt, so we disarm — the bar can't linger or let you answer twice.
    private func detectPrompt() {
        guard busy, !stopping else { return }
        // The last non-empty, non-progress line currently in the buffer.
        let lastLine = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let isPrompt = lastLine.range(of: "\\[y/n\\]\\s*$|\\(y/N\\)\\s*$|\\?\\s*\\[Y/n\\]\\s*$",
                                      options: [.regularExpression, .caseInsensitive]) != nil
        if isPrompt {
            if !awaitingInput { awaitingInput = true; promptText = lastLine }
        } else if awaitingInput {
            // brew moved past the prompt (echoed the answer / started working).
            awaitingInput = false; promptText = ""
        }
    }

    /// Answer a pending `[y/n]` prompt. brew reads a single character via `$stdin.getch`, so we send
    /// one byte (no newline). "n" makes brew `exit 1`, which our completion reports as a non-zero
    /// exit — the console shows "Needs attention" with the abort noted by brew itself.
    /// Disarms immediately so a rapid second click can't send a stray extra character.
    func answer(_ proceed: Bool) {
        guard busy, awaitingInput else { return }
        awaitingInput = false; promptText = ""
        runner?.send(proceed ? "y" : "n")
    }

    /// Recover from a detected failure by running the fix appropriate to its kind, then re-running
    /// (or forcing) the exact command that failed. Console output is preserved so the user sees the
    /// whole recovery story in one log. All commands use fixed arguments (no shell interpolation),
    /// matching every other command in the app.
    func performRecovery() {
        guard ready, !busy, let hint = recovery else { return }
        let command = lastArguments
        guard !command.isEmpty else { return }
        recovery = nil
        switch hint.kind {
        case .resumableDownload:
            // Stage one: clear the stale cached download. `brew cleanup <token>` deletes the partial
            // file curl couldn't resume; fall back to a global cleanup when brew didn't name a
            // package. Then, regardless of cleanup's exit, re-run the original command.
            var cleanupArguments = ["cleanup"]
            if let token = hint.token,
               token.range(of: "^[A-Za-z0-9][A-Za-z0-9@+._/-]*$", options: .regularExpression) != nil {
                cleanupArguments.append(token)
            }
            execute(arguments: cleanupArguments) { [weak self] _, cancelled in
                guard let self = self, !cancelled else { return }
                self.rerunOriginal(command)
            }
        case .staleAppArtifact:
            // The leftover `.app` blocks the install; re-run the exact command with `--force`
            // appended (unless it's already there) so brew overwrites the existing artifact.
            var forced = command
            if !forced.contains("--force") { forced.append("--force") }
            rerunOriginal(forced)
        }
    }

    /// Re-run a maintenance command as part of a recovery, preserving the console log and mirroring
    /// the side effects the original command would have triggered.
    private func rerunOriginal(_ command: [String]) {
        execute(arguments: command, preserveOutput: true) { [weak self] code, cancelled in
            guard let self = self else { return }
            self.inventoryStale = true; self.updatesStale = true
            if code == 0 && !cancelled { self.checkUpdates(preserveOutput: true) }
        }
    }

    /// Dismiss the recovery offer without acting (the user will handle it themselves).
    func dismissRecovery() { recovery = nil }

    /// Parse the just-flushed `text` line-by-line for brew's download markers and update the pinned
    /// live-download block (`downloads`). Homebrew's parallel queue reports several packages at once,
    /// so we key an entry per package name and rebuild the block from these entries — each row always
    /// pairs the right name with the right bytes (no mismatch), and the block can't stack/garble
    /// because we own it. A single unnamed download (percentage-only bar) is tracked as one entry.
    /// Progress lines arrive `\r`-separated within a flush, so we split on both newlines and CRs.
    private func detectDownload(in text: String) {
        guard busy, !stopping else { return }
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            switch DownloadProgressParser.parse(line: String(raw)) {
            case .start(let url, let fileName):
                // Percentage-only path: a single named download with no byte totals yet.
                _ = url
                singleDownloadName = fileName
                upsert(name: fileName, received: 0, total: 0, fractionOverride: 0, done: false)
            case .progress(let fraction):
                // Advance the single-download entry's percentage (ignored if no download started).
                if let name = singleDownloadName {
                    upsert(name: name, received: 0, total: 0, fractionOverride: fraction, done: false)
                }
            case .bytes(let received, let total, let name, let complete):
                // brew's parallel-queue byte counter — authoritative. Key by the reported name; when
                // brew omits a name (rare), fall back to the single-download slot.
                let key = name ?? singleDownloadName ?? "Downloading…"
                if name != nil { singleDownloadName = nil }  // real parallel data supersedes the bar
                upsert(name: key, received: received, total: total, fractionOverride: nil, done: complete)
                // Option (b): if every tracked entry is now complete, commit the block to the log.
                if !downloads.isEmpty && downloads.allSatisfy({ $0.done }) { commitDownloads() }
            case .finish:
                // A non-download step (Installing/Pouring/…) or a completed single download: commit
                // and clear the whole block so it doesn't linger into the install phase.
                commitDownloads()
            case .none:
                break
            }
        }
    }

    /// Insert or update a keyed download entry, preserving insertion order for the pinned block.
    private func upsert(name: String, received: Int64, total: Int64, fractionOverride: Double?, done: Bool) {
        if let idx = downloads.firstIndex(where: { $0.name == name }) {
            var entry = downloads[idx]
            if total > 0 { entry.receivedBytes = received; entry.totalBytes = total; entry.fractionOverride = nil }
            else if let f = fractionOverride { entry.fractionOverride = f }
            if done { entry.done = true }
            downloads[idx] = entry
        } else {
            downloadOrder.append(name)
            downloads.append(DownloadEntry(name: name, receivedBytes: received, totalBytes: total,
                                           done: done, fractionOverride: total > 0 ? nil : fractionOverride))
        }
    }

    /// Finalize the live block: fold a text snapshot of the completed downloads into the scrollback
    /// log (so Copy and history keep a record), then clear the pinned block.
    private func commitDownloads() {
        guard !downloads.isEmpty else { clearDownload(); return }
        var snapshot = ""
        for entry in downloads {
            let mark = entry.done ? "✓" : "·"
            snapshot += "  \(mark) \(entry.name) — \(entry.byteSummary)\n"
        }
        append(snapshot)
        clearDownload()
    }

    /// Clear the pinned live-download block (no snapshot). Used on stop/clear/command-end.
    private func clearDownload() {
        singleDownloadName = nil
        downloadOrder.removeAll()
        if !downloads.isEmpty { downloads = [] }
    }
    /// Appends `text` to `output`, treating a bare carriage return as "move to the start of the
    /// current line and overwrite it". This keeps live progress bars on one line and leaves the
    /// stored `output` clean for the Console view and the Copy button.
    ///
    /// Processes the incoming text in bulk segments split on `\r` rather than character-by-character.
    /// A carriage return can rewrite the current line many times per second during brew's parallel
    /// download queue; the old per-character loop did an O(n) `removeSubrange` on every `\r`, which
    /// starved the main thread as `output` grew. This version does at most one line-truncation per
    /// `\r` and appends whole segments, so cost is proportional to the incoming delta.
    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        // Split on carriage returns, keeping track so a trailing empty segment (text ended with \r)
        // still erases the current line. `components(separatedBy:)` yields N+1 pieces for N returns.
        let segments = text.components(separatedBy: "\r")
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                // A carriage return preceded this segment: erase back to the start of the current
                // line (everything after the last newline).
                if let newline = output.lastIndex(of: "\n") {
                    output.removeSubrange(output.index(after: newline)..<output.endIndex)
                } else {
                    output.removeAll(keepingCapacity: true)
                }
            }
            if !segment.isEmpty { output.append(segment) }
        }
        if output.utf8.count > limit {
            output = "[Earlier output trimmed; showing recent output]\n" + String(output.suffix(limit / 2))
            truncated = true
        }
    }
    /// Fetch rich detail for one package to show in its info popover (Feature 2). Uses a quiet JSON
    /// capture to a temp file (like `refreshInstalled`), so the console isn't spammed. Gated by the
    /// one-command `!busy` invariant. `id` is the row's `kind:token`; opening a popover sets
    /// `infoTarget` immediately (so the UI can anchor) and this fills `packageInfo` when ready.
    func fetchInfo(token: String, kind: String, id: String) {
        guard ready, !busy else { return }
        guard token.range(of: "^[A-Za-z0-9][A-Za-z0-9@+._/-]*$", options: .regularExpression) != nil else {
            infoError = "Cannot look up this package."; return
        }
        infoTarget = id; packageInfo = nil; infoError = nil; infoLoading = true
        let flag = kind == "App" ? "--cask" : "--formula"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BrewBar-pkginfo-\(UUID().uuidString).json")
        execute(arguments: ["info", "--json=v2", flag, token], standardOutputFile: file, preserveOutput: true) { [weak self] code, cancelled in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let self = self else { return }
            self.infoLoading = false
            // If the user closed the popover (or opened a different one) meanwhile, drop the result.
            guard self.infoTarget == id else { return }
            guard code == 0 && !cancelled else {
                self.infoError = cancelled ? "Cancelled." : "Could not load details. See the console."
                return
            }
            if let info = PackageInfo.parse(Data((try? Data(contentsOf: file)) ?? Data())) {
                self.packageInfo = info
            } else {
                self.infoError = "No details available for this package."
            }
        }
    }

    /// Close the info popover and drop any loaded/loading detail.
    func dismissInfo() { infoTarget = nil; packageInfo = nil; infoError = nil; infoLoading = false }

    /// Silent background check for outdated packages (Feature 1). Runs `brew outdated --json=v2`
    /// on its OWN `CommandRunner` — it does NOT go through `execute`, so it never writes to the
    /// console, never toggles `busy`, and never disturbs a running/idle foreground command. Only
    /// `updateCount` (and the badge) is updated. Skipped entirely while a foreground command is
    /// busy or while brew isn't ready, so it can't collide with user actions.
    private var backgroundChecker: CommandRunner?
    private var updateCheckTimer: Timer?
    func backgroundCheckUpdates() {
        guard ready, !busy, brewPath != nil, backgroundChecker == nil else { return }
        guard let path = brewPath else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BrewBar-bg-\(UUID().uuidString).json")
        let checker = CommandRunner(); backgroundChecker = checker
        checker.run(executable: path, arguments: ["outdated", "--json=v2"], environment: environment,
                    standardOutputFile: file, usePTY: false) { _ in
        } completion: { [weak self] code, cancelled in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let self = self else { return }
            self.backgroundChecker = nil
            guard code == 0 && !cancelled else { return }
            if let list = try? PackageUpdate.parse(Data(contentsOf: file)) {
                self.updateCount = list.count
                // If the Updates tab hasn't been loaded/hydrated yet, seed it so the count is
                // consistent when the user opens it (without marking a manual check timestamp).
                if !self.updatesLoaded {
                    self.updates = list; self.updatesLoaded = true; self.updatesStale = true
                }
            }
        }
    }

    /// Start the periodic background update check: once shortly after launch, then every 6 hours.
    /// Idempotent — calling twice won't stack timers.
    func startBackgroundUpdateChecks() {
        guard updateCheckTimer == nil else { return }
        // A short delay after launch lets environment resolution (`prepare`) finish first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            Task { @MainActor in self?.backgroundCheckUpdates() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.backgroundCheckUpdates() }
        }
        updateCheckTimer = timer
    }

    /// The exact `brew bundle dump` arguments for exporting a Brewfile to `path`. Kept as a pure
    /// helper so a test can pin the flag set — current Homebrew (7+) removed `--describe` and errors
    /// out if it's passed, so this must stay `dump --force --file=<path>` (descriptions are the
    /// default). `--force` overwrites any existing file at the path.
    static func brewfileDumpArguments(path: String) -> [String] {
        ["bundle", "dump", "--force", "--file=\(path)"]
    }

    /// Export the current Homebrew setup to a Brewfile (Feature 4). Shows a save panel (default name
    /// `Brewfile` in the home folder), then runs `brew bundle dump --file=<path> --force` — fixed
    /// args, the only interpolated value being the user-picked path from the panel (not shell-parsed;
    /// passed as a single argv element). Output stays in the console like any other command.
    /// Bring the app + a panel to the front before running it modally, and return the previous
    /// activation policy so the caller can restore it afterward.
    ///
    /// A `MenuBarExtra(.window)` app is an `LSUIElement`/accessory app: it never becomes a real
    /// foreground app, so a modal `NSSavePanel`/`NSOpenPanel` can't reliably own focus and opens
    /// BEHIND the high-level BrewBar popover (it appears as a stranded, unfocused window). Merely
    /// calling `activate(ignoringOtherApps:)` + raising the panel level is not enough.
    ///
    /// The fix is to temporarily promote the app to `.regular` so it becomes a normal foreground
    /// app that can present a focused, front-most modal panel. `restoreActivationPolicy(_:)` puts
    /// it back to `.accessory` once the panel closes. Call immediately before `runModal()`.
    @discardableResult
    private func bringPanelToFront(_ panel: NSSavePanel) -> NSApplication.ActivationPolicy {
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        panel.level = .modalPanel
        // Order the panel in front and make it key so keyboard focus lands in the name field.
        panel.makeKeyAndOrderFront(nil)
        return previous
    }

    /// Restore the activation policy captured by `bringPanelToFront(_:)` after the modal panel has
    /// closed, so the app goes back to being a menu-bar-only accessory (no Dock icon).
    private func restoreActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        // Only demote back to accessory; if it was already regular for some reason, leave it.
        if policy != .regular {
            NSApplication.shared.setActivationPolicy(policy)
        }
    }

    func exportBrewfile() {
        guard ready, !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Export Brewfile"
        panel.message = "Save a Brewfile snapshot of your installed formulae, casks, and taps."
        panel.nameFieldStringValue = "Brewfile"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        let previousPolicy = bringPanelToFront(panel)
        let response = panel.runModal()
        restoreActivationPolicy(previousPolicy)
        guard response == .OK, let url = panel.url else { return }
        // `--force` overwrites an existing file at the chosen path (the user already confirmed the
        // save panel's own replace prompt). Description comments are Homebrew's default; we don't
        // pass `--describe` because current Homebrew (7+) removed that switch and rejects it.
        execute(arguments: Self.brewfileDumpArguments(path: url.path)) { [weak self] code, cancelled in
            guard let self = self else { return }
            if code == 0 && !cancelled { self.append("Brewfile saved to \(url.path)\n") }
        }
    }

    /// Pick a Brewfile to restore from (Feature 4). Shows an open panel; on selection, stashes the
    /// URL in `brewfileRestoreCandidate` so the UI can show a confirmation before anything runs.
    func chooseBrewfileToRestore() {
        guard ready, !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Restore from Brewfile"
        panel.message = "Choose a Brewfile to install its formulae, casks, and taps."
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        let previousPolicy = bringPanelToFront(panel)  // NSOpenPanel is an NSSavePanel subclass; same front-ordering fix.
        let response = panel.runModal()
        restoreActivationPolicy(previousPolicy)
        guard response == .OK, let url = panel.url else { return }
        brewfileRestoreCandidate = url
    }

    /// Confirm and run the restore: `brew bundle install --file=<path>`. This can install many
    /// packages, so it's gated behind the explicit confirmation set up by `chooseBrewfileToRestore`.
    func confirmRestoreBrewfile() {
        guard ready, !busy, let url = brewfileRestoreCandidate else { return }
        brewfileRestoreCandidate = nil
        execute(arguments: ["bundle", "install", "--file=\(url.path)"]) { [weak self] code, cancelled in
            guard let self = self else { return }
            // A restore can install/upgrade many packages; everything is now stale.
            self.inventoryStale = true; self.updatesStale = true
            if code == 0 && !cancelled { self.append("Brewfile restore complete.\n") }
        }
    }

    /// Cancel a pending restore without running anything.
    func cancelRestoreBrewfile() { brewfileRestoreCandidate = nil }

    func stop() { guard busy else { return }; stopping = true; awaitingInput = false; promptText = ""; clearDownload(); recovery = nil; status = "Stopping…"; runner?.cancel() }
    func clear() { output = ""; pending.removeAll(); truncated = false; clearDownload(); recovery = nil }
    func copy() {
        var text = output
        if !downloads.isEmpty {
            var snapshot = "\nDownloads:\n"
            for entry in downloads {
                let mark = entry.done ? "✓" : "·"
                snapshot += "  \(mark) \(entry.name) — \(entry.byteSummary)\n"
            }
            text += snapshot
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
