import AppKit
import SwiftUI
import CryptoKit

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
    // In-app update check (Phase 1). Detect-and-guide: a background check compares the latest
    // GitHub release tag to the running app version and, when newer, surfaces it in the Options
    // menu and a header banner. Clicking opens the release page (no self-replace yet).
    @Published var appUpdateAvailable = false
    /// The latest available app version (display form, e.g. "1.26"), when a newer release exists.
    @Published var latestAppVersion: String?
    /// True while a manual "Check for Updates…" is in flight (drives the menu label/spinner).
    @Published var checkingAppUpdate = false
    /// A short status from the most recent manual check ("You're up to date." / an error), shown
    /// briefly in the Options menu. Nil when there's nothing to say.
    @Published var appUpdateStatus: String?
    /// Phase 2 self-update progress. `installingUpdate` gates the UI into a progress state;
    /// `updateInstallProgress` is 0…1 during the download; `updateInstallStage` is a short label
    /// ("Downloading…", "Verifying…", "Installing…"). Set back to idle on failure.
    @Published var installingUpdate = false
    @Published var updateInstallProgress: Double = 0
    @Published var updateInstallStage = ""
    /// The download URL + tag resolved by the latest successful update check, so the one-click
    /// install knows exactly what to fetch without re-hitting the API.
    private var pendingUpdateURL: URL?
    private var pendingUpdateTag: String?
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
    /// True while the running command is blocked on `sudo`'s admin-password prompt — a cask whose
    /// payload runs `/usr/sbin/installer -pkg` (e.g. `zoom`). The console then shows a secure
    /// password field wired to `submitPassword(_:)` / `cancelPassword()`. The password BrewBar
    /// collects is handed to sudo through `AskpassBroker` (an in-memory → FIFO channel; it never
    /// touches argv, env, or a regular file). Set from the broker's request watcher.
    @Published var awaitingPassword = false
    /// The admin-password the user is typing into the secure field (bound via `PasswordPromptBar`).
    /// Lives only in memory and is cleared the instant it's submitted or the prompt is dismissed —
    /// it is never logged, placed in argv/env, or written to disk. It transits to sudo only through
    /// the `AskpassBroker`'s private FIFO.
    @Published var passwordDraft = ""
    /// The broker answering sudo's askpass for the current cask command. Created only for cask
    /// install/upgrade commands; torn down when the command ends / stops / the console is cleared.
    private var askpass: AskpassBroker?
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
    /// A trailing partial line held back from the DownloadProgressParser until the next flush
    /// completes it. A flush slice can split a line mid-way; feeding a fragment to the parser can
    /// spuriously match a finish pattern (firing a mid-download commit) or miss a start line. We only
    /// ever hand the parser COMPLETE lines, carrying the unfinished tail here. Cleared on command
    /// start / clear / stop. (Only affects the structured download block; the console mirror still
    /// gets brew's exact bytes.)
    private var cleanRemainder = ""
    private var outputTimer: Timer?
    private var resolutionID = UUID()
    private var truncated = false
    private let limit = 500_000
    /// Line-oriented terminal emulator that renders brew's live output (CR/cursor-up redraws, erase
    /// line) exactly like a real terminal. All writes to `output` go through it so the console mirror
    /// matches Terminal.app — in particular, the parallel download queue's multi-line in-place redraw
    /// collapses onto one block instead of stacking/garbling. See TerminalEmulator for the details.
    private var terminal = TerminalEmulator()
    /// Whether the current command runs under a PTY. On a PTY, brew performs real in-place redraws
    /// (the download queue moves the cursor up/to-col-0), so the emulator must honour LF's
    /// column-preserving behaviour. On a plain pipe (JSON captures: outdated/info/search) brew emits
    /// progressive plain lines expecting each to start at column 0 and never issues a carriage
    /// return — so we normalise bare LF to CR+LF before feeding the emulator, keeping those lines at
    /// the left margin instead of inheriting the previous line's stale column.
    private var usingPTY = false

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
            if code != 0 { self.setOutput("Login environment unavailable; using standard Homebrew paths.\n") }
            if !self.ready { self.append("Install Homebrew from brew.sh, then choose Retry.\n") }
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
        awaitingPassword = false; passwordDraft = ""; teardownAskpass()
        lastArguments = arguments
        started = Date(); finished = nil; command = "brew " + arguments.joined(separator: " "); status = "Running"
        pending.removeAll(); truncated = false; cleanRemainder = ""
        let heading = "[\(Date().formatted(date: .omitted, time: .standard))] $ \(command)\n"
        // When preserving the previous log (a chained command: search→info, upgrade→recheck, etc.)
        // the heading is appended after the prior command's status line, whose trailing `\n` leaves
        // the cursor at that line's stale column (a bare LF preserves the column — correct terminal
        // behaviour, see TerminalEmulator). Prefix the blank-line separator with CR so the heading
        // starts at column 0 instead of being indented to the stale column.
        if preserveOutput { append("\r\n" + heading) } else { terminal.reset(); setOutput(heading) }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Homebrew maintenance")
        let process = CommandRunner(); runner = process
        usingPTY = standardOutputFile == nil
        // A cask install/upgrade may run a `.pkg` installer that needs `sudo`. For those commands,
        // wire up a secure askpass broker: brew sees `SUDO_ASKPASS=<helper>` → passes `sudo -A` →
        // sudo runs our helper → the helper signals us and waits for the password on a private FIFO.
        // Every other command keeps the environment's `SUDO_ASKPASS=/usr/bin/false` so an unexpected
        // sudo still fails fast rather than hanging on a hidden prompt. Only on the PTY path (no
        // standardOutputFile) — JSON captures never install anything.
        var commandEnvironment = environment
        if standardOutputFile == nil, Self.commandMayNeedAdminPassword(arguments),
           let broker = try? AskpassBroker() {
            askpass = broker
            commandEnvironment["SUDO_ASKPASS"] = broker.helperPath
            broker.startWatching { [weak self] in
                guard let self = self, self.busy, !self.stopping else { return }
                self.awaitingPassword = true
            }
        }
        outputTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        // Interactive commands run under a PTY so brew emits its live progress bar. JSON captures
        // (standardOutputFile set) stay on a plain pipe for clean, parseable output.
        process.run(executable: path, arguments: arguments, environment: commandEnvironment,
                    standardOutputFile: standardOutputFile, usePTY: standardOutputFile == nil) { [weak self] data in
            self?.pending.append(data)
        } completion: { [weak self] code, cancelled in
            guard let self = self else { return }
            self.flush(final: true)
            self.outputTimer?.invalidate(); self.outputTimer = nil
            self.exitCode = code; self.finished = Date(); self.busy = false; self.stopping = false
            self.awaitingInput = false; self.promptText = ""; self.clearDownload()
            self.awaitingPassword = false; self.passwordDraft = ""; self.teardownAskpass()
            self.failed = code != 0 && !cancelled
            self.status = cancelled ? "Cancelled" : (code == 0 ? "Succeeded" : "Needs attention")
            // Offer a one-click fix when the failure is a resumable-download dead-end (curl-56 /
            // "Cannot resume"). Only for a real (non-cancelled) failure of a retryable command.
            if self.failed, let hint = RecoveryHintDetector.detect(in: self.output) { self.recovery = hint }
            var trimmed = self.output
            while trimmed.last == "\n" || trimmed.last == "\r" { trimmed.removeLast() }
            self.setOutput(trimmed)
            // Prefix the synthetic status line with CR+LF, not just LF: after `setOutput` re-seeds
            // the emulator the cursor sits at the END of brew's last output line, and a bare LF
            // preserves the column (correct terminal behaviour) — which would indent this status
            // line to that stale column. The CR resets to column 0 so it always starts at the left
            // margin. Same for the cancelled-rollback note below.
            self.append("\r\n[\(Date().formatted(date: .omitted, time: .standard))] \(self.status) · Exit \(code)\n")
            if cancelled { self.append("\rCompleted changes are not rolled back. Run Doctor to check Homebrew.\n") }
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
                self.append("\rLoaded \(self.packages.count) installed Homebrew packages.\n")
            } catch {
                self.failed = true; self.status = "Could not read packages"
                self.inventoryError = "Homebrew returned an unreadable package list. Try Refresh."
                self.inventoryStale = true
                self.append("\rCould not decode package list: \(error.localizedDescription)\n")
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
                self.append("\rFound \(self.searchResults.count) installable packages for “\(query)”.\n")
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
                self.append("\r\(self.updates.count) available updates in current definitions.\n")
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
            // Also keep an incomplete ANSI escape sequence until the following read. Homebrew's
            // parallel download queue rewrites its block every ~0.05s with CSI cursor-motion /
            // erase codes (`ESC[1F`, `ESC[K`, `ESC[?2026h/l`). A 0.1s flush slice can end in the
            // MIDDLE of one of those sequences; feeding the fragment to the emulator makes
            // `consumeEscape` run off the end and silently drop the sequence, so a frame's cursor-up
            // or erase is lost and the block drifts/garbles. Reduce `count` to before any trailing
            // unterminated ESC so the whole sequence is emitted together next time. (Operate on a
            // stable byte array — `Data` indices rebase after `removeFirst`.)
            count = Self.escapeSafeCount([UInt8](pending), upTo: count)
        }
        guard count > 0 else { return }
        let text = String(decoding: pending.prefix(count), as: UTF8.self)
        pending.removeFirst(count)
        // Feed brew's raw output (control sequences intact) to the terminal emulator via append; it
        // honours CR, cursor-up (`ESC[nF`), erase-line (`ESC[K`) and the synchronized-update markers
        // so the parallel download queue's multi-line redraw collapses onto one block, matching a
        // real terminal. (Previously flush pre-translated `ESC[0G`→CR and stripped the rest, which
        // discarded the cursor-up and let multi-item frames stack/garble.)
        //
        // On a plain pipe (JSON captures: outdated/info/search — no PTY) brew does NOT do in-place
        // redraws and never issues a carriage return; it just prints progressive lines (e.g. the
        // `==> Auto-updating Homebrew…` / `==> Auto-updated Homebrew!` preamble) each meant to start
        // at column 0. Because a bare LF preserves the column in a faithful terminal, those lines
        // would otherwise inherit the previous line's stale column and stair-step to the right. So
        // for the non-PTY path, turn each bare LF into CR+LF (CR first resets to column 0) before
        // feeding the emulator. Existing CRs are untouched (we don't double a CR already present).
        let feed = usingPTY ? text : Self.normalizeLineBreaks(text)
        append(feed)
        // The structured live-download block (DownloadProgressParser) wants clean, control-free
        // lines. Strip ANSI and normalise CR/CUP to newlines for the parser's input only — the
        // console mirror above keeps brew's exact in-place rendering.
        var clean = cleanRemainder + text
        cleanRemainder = ""
        clean = clean.replacingOccurrences(of: "\u{001B}\\[[0-9]*[GF]", with: "\n", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "\r\n", with: "\n")
        // The parser must only ever see COMPLETE lines. A flush slice can split a line mid-way; a
        // fragment can spuriously match a finish pattern (`==>` / `Downloaded`) and fire a mid-
        // download commit (leaking a `· name — …` snapshot into the scrollback), or miss a start
        // line entirely. Hold back the trailing partial line (everything after the last newline/CR)
        // until the next flush completes it. On the final flush, emit whatever remains.
        if !final, let lastBreak = clean.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let split = clean.index(after: lastBreak)
            cleanRemainder = String(clean[split...])
            clean = String(clean[..<split])
        } else if !final {
            // No line break at all this slice — the whole thing is an unfinished line; defer it.
            cleanRemainder = clean
            clean = ""
        }
        detectPrompt()
        if !clean.isEmpty { detectDownload(in: clean) }
    }

    /// Return how many of the first `upTo` bytes of `data` are safe to emit without cutting an ANSI
    /// escape sequence in half. If the slice ends in an unterminated escape — a trailing `ESC`
    /// (`0x1B`), or an `ESC` followed by CSI/OSC-introducer bytes with no final byte yet — the count
    /// is reduced to just before that `ESC` so the complete sequence is emitted on the next flush.
    /// A CSI sequence (`ESC[`) terminates on a byte in 0x40–0x7E; an OSC (`ESC]`) on BEL or ESC\\.
    static func escapeSafeCount(_ data: [UInt8], upTo: Int) -> Int {
        // Scan backward from the slice end for the last ESC within a short window (sequences are
        // short; brew's are < 12 bytes). If that ESC's sequence isn't terminated inside the slice,
        // hold back from the ESC.
        let esc: UInt8 = 0x1B
        var i = upTo - 1
        let floor = max(0, upTo - 24)
        while i >= floor {
            if data[i] == esc {
                // Does a terminated sequence end before `upTo`? Check the bytes after this ESC.
                if isCompleteEscape(data, start: i, end: upTo) { return upTo }
                return i   // unterminated — hold back from here
            }
            i -= 1
        }
        return upTo
    }

    /// Whether the escape sequence beginning at `start` (where `data[start] == ESC`) is fully
    /// contained in `data[start..<end]`.
    private static func isCompleteEscape(_ data: [UInt8], start: Int, end: Int) -> Bool {
        guard start + 1 < end else { return false }  // just a lone ESC
        let second = data[start + 1]
        switch second {
        case UInt8(ascii: "["):  // CSI: parameters/intermediates, then a final byte 0x40–0x7E.
            var j = start + 2
            while j < end {
                let b = data[j]
                if b >= 0x40 && b <= 0x7E { return true }  // final byte
                j += 1
            }
            return false
        case UInt8(ascii: "]"):  // OSC: terminated by BEL (0x07) or ESC\ (0x1B 0x5C).
            var j = start + 2
            while j < end {
                if data[j] == 0x07 { return true }
                if data[j] == 0x1B && j + 1 < end && data[j + 1] == 0x5C { return true }
                j += 1
            }
            return false
        default:
            // Two-byte escape (e.g. ESC(B) or a control we don't special-case: complete once the
            // second byte is present.
            return true
        }
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

    /// Whether `arguments` could trigger a `sudo` admin-password prompt — i.e. a cask operation whose
    /// payload runs a privileged step (a `.pkg` installer via `/usr/sbin/installer`, or removing
    /// launchctl services / pkg receipts on uninstall), like `zoom`. We enable the askpass broker for:
    ///   • `install` / `reinstall` / `upgrade` that includes `--cask`
    ///   • a bare `upgrade` (no package named) — it upgrades everything, which may include casks
    ///   • `uninstall` / `zap` that includes `--cask` (removes services + pkg receipts via sudo)
    /// Formula-only commands never need sudo (Homebrew installs into a user-writable prefix), and
    /// read-only/JSON commands (outdated/info/search/list) never touch privileged state. Pure/static
    /// for testing.
    static func commandMayNeedAdminPassword(_ arguments: [String]) -> Bool {
        guard let verb = arguments.first else { return false }
        switch verb {
        case "install", "reinstall", "uninstall", "zap":
            return arguments.contains("--cask")
        case "upgrade":
            // `brew upgrade` with no token upgrades all installed packages (casks included).
            let hasToken = arguments.dropFirst().contains { !$0.hasPrefix("-") }
            return arguments.contains("--cask") || !hasToken
        default:
            return false
        }
    }

    /// Deliver the admin password the user typed to the waiting `sudo` (via the askpass broker's
    /// private FIFO). The password is passed straight to the broker and NOT stored on the model —
    /// the caller (the secure field binding) is responsible for clearing its own copy. Disarms the
    /// prompt immediately; sudo may re-ask (wrong password / another authentication), which re-arms
    /// it through the broker's request watcher.
    func submitPassword(_ password: String) {
        guard busy, awaitingPassword else { return }
        awaitingPassword = false
        askpass?.sendPassword(password)
        passwordDraft = ""
    }

    /// Decline the admin-password prompt: tell the broker to hand sudo an empty password so it fails
    /// authentication and brew aborts the cask cleanly (reported as "Needs attention"). Used by the
    /// prompt bar's Cancel button.
    func cancelPassword() {
        guard busy, awaitingPassword else { return }
        awaitingPassword = false
        askpass?.declineOnce()
        passwordDraft = ""
    }

    /// Stop watching and remove the askpass broker's private channel (idempotent). Called when a
    /// command finishes, on Stop, and on Clear so the FIFOs/helper never outlive their command.
    private func teardownAskpass() {
        askpass?.cleanup()
        askpass = nil
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
    /// Appends `text` to the console by feeding it to the terminal emulator, then publishes the
    /// emulator's rendered screen as `output`. `text` may contain brew's raw control sequences
    /// (carriage returns, cursor-up/`ESC[nF`, erase-line/`ESC[K`, synchronized-update markers); the
    /// emulator honours them so progress bars rewrite in place and the parallel download queue's
    /// multi-line redraw collapses onto one block exactly like a real terminal. Plain status/snapshot
    /// text (no control codes) is handled identically — it just appends.
    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        terminal.feed(text)
        if terminal.trim(toUTF8: limit) { truncated = true }
        output = terminal.render()
    }
    /// Turn every bare line feed into CR+LF so each line starts at column 0 when fed to the terminal
    /// emulator. Used only for the non-PTY (plain-pipe) path, where brew prints progressive plain
    /// lines with no carriage returns of its own. A `\r` already preceding a `\n` is preserved (we do
    /// not insert a second CR); a lone `\r` (none of brew's non-PTY output emits these, but be
    /// safe) is left as-is. Pure/static so it can be unit-tested without a model instance.
    static func normalizeLineBreaks(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count + 8)
        var previous: Character? = nil
        for ch in text {
            if ch == "\n" && previous != "\r" { result.append("\r") }
            result.append(ch)
            previous = ch
        }
        return result
    }
    /// Replace the console contents outright (a command heading, an error line, or a clear). Keeps the
    /// emulator's cursor consistent with the visible text so a following live redraw lands correctly.
    private func setOutput(_ text: String) {
        terminal.seed(text)
        output = terminal.render()
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
        // First, run a VISIBLE plain `brew info <flag> <token>` so the human-readable detail (the
        // same text you'd see in Terminal — description, homepage, install state, artifacts,
        // analytics) streams into the console. Then chain the quiet JSON capture that fills the
        // popover. Chaining is safe because `execute` sets `busy = false` before calling this
        // completion (the search→info chain relies on the same invariant).
        execute(arguments: ["info", flag, token]) { [weak self] _, cancelled in
            guard let self = self else { return }
            // If the user closed/changed the popover meanwhile, don't bother with the JSON fetch.
            guard self.infoTarget == id, !cancelled else {
                if cancelled && self.infoTarget == id { self.infoLoading = false; self.infoError = "Cancelled." }
                return
            }
            self.loadInfoDetail(token: token, flag: flag, id: id)
        }
    }

    /// Quiet JSON capture (`brew info --json=v2 <flag> <token>` to a temp file, no console spam)
    /// that parses one `PackageInfo` to fill the popover. Chained after the visible plain-text run
    /// in `fetchInfo` so the console shows the Terminal-style detail while the popover still gets
    /// its structured fields. `preserveOutput: true` keeps the plain-text info visible in the log.
    private func loadInfoDetail(token: String, flag: String, id: String) {
        guard ready, !busy else { infoLoading = false; return }
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
        // Check for a new BrewBar release shortly after launch too (independent of Homebrew).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { @MainActor in self?.checkForAppUpdate() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.backgroundCheckUpdates(); self?.checkForAppUpdate() }
        }
        updateCheckTimer = timer
    }

    /// The GitHub release check task, kept so a manual check won't stack concurrent requests.
    private var appUpdateTask: URLSessionDataTask?

    /// Check GitHub Releases for a newer BrewBar and update the Phase-1 state. `manual` shows
    /// transient feedback in the Options menu ("You're up to date." / an error); the silent
    /// background check leaves `appUpdateStatus` untouched on the up-to-date/failure paths so it
    /// never nags. Never blocks the UI (async URLSession), and fails safe: any error leaves
    /// `appUpdateAvailable` false.
    func checkForAppUpdate(manual: Bool = false) {
        guard appUpdateTask == nil else { return }
        if manual { checkingAppUpdate = true; appUpdateStatus = nil }
        var request = URLRequest(url: AppUpdate.latestReleaseAPI)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "2.0.1"
        // On a manual check, print the running build's details to the console so there's a visible
        // record of what's installed alongside the check result.
        if manual { logAppUpdateHeader(current: current) }
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.appUpdateTask = nil
                self.checkingAppUpdate = false
                guard let data = data, error == nil,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let tag = AppUpdate.tagName(fromLatestReleaseJSON: data) else {
                    if manual {
                        self.appUpdateStatus = "Couldn't check for updates. Try again later."
                        self.logAppUpdate("Could not reach GitHub Releases. Check your connection and try again.")
                    }
                    return
                }
                let latest = AppUpdate.displayVersion(fromTag: tag)
                if AppUpdate.isNewer(tag, than: current) {
                    self.appUpdateAvailable = true
                    self.latestAppVersion = latest
                    self.pendingUpdateTag = tag
                    self.pendingUpdateURL = AppUpdate.zipAssetURL(fromLatestReleaseJSON: data)
                        ?? AppUpdate.fallbackZipURL(tag: tag)
                    if manual {
                        self.appUpdateStatus = "BrewBar \(latest) is available."
                        self.logAppUpdate("Update available: BrewBar \(latest) (latest release \(tag)). Use “Update to \(latest)” to download and install it automatically.")
                    }
                } else {
                    self.appUpdateAvailable = false
                    self.latestAppVersion = nil
                    self.pendingUpdateTag = nil
                    self.pendingUpdateURL = nil
                    if manual {
                        self.appUpdateStatus = "You're up to date."
                        self.logAppUpdate("You're up to date — BrewBar \(current) is the latest release.")
                    }
                }
            }
        }
        appUpdateTask = task
        task.resume()
    }

    /// Open the GitHub release page so the user can download the new version (fallback / "release
    /// notes" link; the primary path is the one-click `installUpdate()`).
    func openAppReleasePage() {
        NSWorkspace.shared.open(AppUpdate.latestReleasePage)
    }

    /// One-click self-update (Phase 2). Downloads the resolved release ZIP, verifies its SHA-256
    /// against the published `SHA256SUMS.txt`, unzips it, clears the quarantine flag, then launches
    /// a detached helper that waits for BrewBar to quit, swaps the bundle in place, and relaunches.
    /// Fail-safe: any download/verify/unzip error aborts and leaves the installed app untouched.
    /// No Developer ID / notarization needed — the helper clears quarantine and re-signs ad-hoc.
    func installUpdate() {
        guard !installingUpdate, let url = pendingUpdateURL, let tag = pendingUpdateTag else { return }
        installingUpdate = true; updateInstallProgress = 0; updateInstallStage = "Downloading…"
        let version = AppUpdate.displayVersion(fromTag: tag)
        logAppUpdate("Starting update to BrewBar \(version)…")

        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            // Move the downloaded file synchronously (the temp file is deleted when this returns).
            var stagedZip: URL?
            if let tempURL = tempURL, error == nil,
               (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true {
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BrewBar-update-\(UUID().uuidString).zip")
                try? FileManager.default.moveItem(at: tempURL, to: dest)
                stagedZip = dest
            }
            Task { @MainActor in
                guard let self = self else { return }
                guard let zip = stagedZip else { self.failUpdate("Download failed. Check your connection and try again."); return }
                await self.verifyAndInstall(zip: zip, tag: tag)
            }
        }
        // Reflect download progress on the bar.
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
            Task { @MainActor in self?.updateInstallProgress = prog.fractionCompleted }
        }
        task.resume()
    }

    /// KVO token for the download task's progress (kept alive for the download's duration).
    private var progressObservation: NSKeyValueObservation?

    /// Verify the downloaded ZIP against the published checksums, then unzip + swap. Verification is
    /// best-effort-strict: if we can fetch the checksums and our file's hash isn't listed/matching,
    /// we abort; if the checksums file itself can't be fetched we proceed (the download came from the
    /// same GitHub release), logging that verification was skipped.
    private func verifyAndInstall(zip: URL, tag: String) async {
        updateInstallStage = "Verifying…"
        let expectedName = AppUpdate.assetFileName(forTag: tag)
        if let localHash = sha256Hex(of: zip) {
            if let (data, resp) = try? await URLSession.shared.data(from: AppUpdate.checksumsURL),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let text = String(data: data, encoding: .utf8) {
                let sums = AppUpdate.parseChecksums(text)
                if let expected = sums[expectedName] {
                    guard expected == localHash else {
                        failUpdate("Update verification failed (checksum mismatch). Aborted; your app is unchanged.")
                        return
                    }
                    logAppUpdate("Verified SHA-256 \(localHash.prefix(12))… against SHA256SUMS.txt.")
                } else {
                    logAppUpdate("Checksum for \(expectedName) not published yet; proceeding (download is from the signed release).")
                }
            } else {
                logAppUpdate("Could not fetch SHA256SUMS.txt; proceeding (download is from the release).")
            }
        }
        await unzipAndSwap(zip: zip, tag: tag)
    }

    /// Compute the SHA-256 of a file as lowercase hex (streamed so a large ZIP isn't fully resident).
    private func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzip to a staging dir, locate `BrewBar.app`, clear quarantine, then launch a detached helper
    /// that performs the in-place swap after BrewBar quits, and quit.
    private func unzipAndSwap(zip: URL, tag: String) async {
        updateInstallStage = "Installing…"
        let fm = FileManager.default
        let stageDir = fm.temporaryDirectory.appendingPathComponent("BrewBar-stage-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            // Use ditto to expand while preserving the bundle + code signature.
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, stageDir.path]
            try unzip.run(); unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { failUpdate("Could not expand the update archive. Your app is unchanged."); return }
        } catch {
            failUpdate("Could not expand the update archive. Your app is unchanged."); return
        }
        // Find the new BrewBar.app inside the staging dir.
        guard let newApp = findApp(in: stageDir) else {
            failUpdate("The update didn't contain BrewBar.app. Your app is unchanged."); return
        }
        // Clear quarantine so the swapped copy launches cleanly (ad-hoc signed distribution).
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", newApp.path]
        try? strip.run(); strip.waitUntilExit()

        let installedPath = Bundle.main.bundlePath  // e.g. /Applications/BrewBar.app
        launchSwapHelper(newApp: newApp.path, installedApp: installedPath, stageDir: stageDir.path, zip: zip.path)
        logAppUpdate("Update staged. BrewBar will quit and relaunch on \(AppUpdate.displayVersion(fromTag: tag))…")
        // Give the log a beat to render, then quit so the helper can swap the bundle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    /// Recursively find the first `BrewBar.app` under `dir` (ditto may nest it or place it at root).
    private func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent == "BrewBar.app" { return item }
            for item in items where item.hasDirectoryPath && item.pathExtension != "app" {
                if let found = findApp(in: item) { return found }
            }
        }
        return nil
    }

    /// Write and launch a detached shell helper that waits for this process to exit, swaps the
    /// bundle in place (old moved aside, new moved in; rolled back on failure), relaunches BrewBar,
    /// and cleans up. Runs via `/bin/sh` fully detached so it survives our termination.
    private func launchSwapHelper(newApp: String, installedApp: String, stageDir: String, zip: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        # Wait for BrewBar (pid \(pid)) to exit.
        for i in $(seq 1 100); do
          if ! kill -0 \(pid) 2>/dev/null; then break; fi
          sleep 0.1
        done
        BACKUP="\(installedApp).old-$$"
        # Move the current app aside; if that fails (permissions), abort without damage.
        if ! /bin/mv "\(installedApp)" "$BACKUP" 2>/dev/null; then
          # Try to relaunch the existing app and bail.
          /usr/bin/open "\(installedApp)" 2>/dev/null
          exit 1
        fi
        # Move the new app into place. On failure, roll back the backup.
        if ! /bin/mv "\(newApp)" "\(installedApp)" 2>/dev/null; then
          /bin/mv "$BACKUP" "\(installedApp)" 2>/dev/null
          /usr/bin/open "\(installedApp)" 2>/dev/null
          exit 1
        fi
        # Success: remove backup + staging, relaunch the new app.
        /bin/rm -rf "$BACKUP" "\(stageDir)" "\(zip)" 2>/dev/null
        /usr/bin/open "\(installedApp)"
        exit 0
        """
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewBar-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [helper.path]
            try proc.run()  // detached: we terminate right after, the helper keeps running
        } catch {
            failUpdate("Couldn't start the updater helper. Your app is unchanged.")
        }
    }

    /// Reset install state and surface a failure both in the menu and the console.
    private func failUpdate(_ message: String) {
        installingUpdate = false; updateInstallProgress = 0; updateInstallStage = ""
        progressObservation = nil
        appUpdateStatus = message
        logAppUpdate(message)
    }

    /// Print the running build's details to the console when the user manually checks for updates,
    /// so there's a visible record of exactly what's installed. Skipped while a foreground command
    /// is running so it never interleaves with live command output (the menu still shows status).
    private func logAppUpdateHeader(current: String) {
        guard !busy else { return }
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let identifier = info?["CFBundleIdentifier"] as? String ?? "com.brewbar.app"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let bundlePath = Bundle.main.bundlePath
        let stamp = Date().formatted(date: .omitted, time: .standard)
        // Each line is prefixed with a carriage return so it resets to column 0 before the text is
        // written. These lines are appended after a prior command's output whose trailing bare LF
        // (correctly, per the v1.28 terminal fix) PRESERVES the column — without the leading CR the
        // whole About block would inherit that stale column and cascade progressively to the right
        // (each internal `\n` also preserves the column, so every row shifts further than the last).
        var text = "\r[\(stamp)] Checking for BrewBar updates…\n"
        // Align the values in a fixed column by padding each label to the width of the longest one,
        // rather than hand-typed spaces (which previously left "Current version:" one column off
        // from the others). `row` right-pads the label to `labelWidth`, so every value starts at the
        // same column regardless of label length.
        let labelWidth = 16  // length of the longest label ("Current version:")
        func row(_ label: String, _ value: String) -> String {
            "\r  " + label.padding(toLength: labelWidth, withPad: " ", startingAt: 0) + " \(value)\n"
        }
        text += row("Current version:", "\(current) (build \(build))")
        text += row("Bundle ID:", identifier)
        text += row("Location:", bundlePath)
        text += row("macOS:", os)
        append(text)
    }

    /// Print a single update-check result line to the console (guarded like the header). Prefixed
    /// with a carriage return for the same reason as the header: the preceding line's bare LF leaves
    /// the cursor at a stale column, so reset to column 0 before writing.
    private func logAppUpdate(_ message: String) {
        guard !busy else { return }
        append("\r  \(message)\n")
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
            if code == 0 && !cancelled { self.append("\rBrewfile saved to \(url.path)\n") }
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
            if code == 0 && !cancelled { self.append("\rBrewfile restore complete.\n") }
        }
    }

    /// Cancel a pending restore without running anything.
    func cancelRestoreBrewfile() { brewfileRestoreCandidate = nil }

    func stop() { guard busy else { return }; stopping = true; awaitingInput = false; promptText = ""; awaitingPassword = false; passwordDraft = ""; teardownAskpass(); clearDownload(); recovery = nil; status = "Stopping…"; runner?.cancel() }
    func clear() { terminal.reset(); output = ""; pending.removeAll(); cleanRemainder = ""; truncated = false; clearDownload(); recovery = nil }
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
