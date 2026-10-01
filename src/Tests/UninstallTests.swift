import AppKit
import Foundation

// Stand-in for UI-only image loading when testing the model without the app entry point.
enum BrandImages { static func icon(dark: Bool) -> NSImage { NSImage(size: NSSize(width: 18, height: 18)) } }

@main struct UninstallTests {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = folder.appendingPathComponent("fake-brew")
        try """
        #!/bin/sh
        printf '%s\\n' "$@"
        case "$3" in
          fail) printf 'Dependency prevents removal\\n' >&2; exit 1 ;;
          slow) sleep 30 ;;
          *) exit 0 ;;
        esac
        """.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let model = BrewModel(prepareOnLaunch: false)
        model.ready = true; model.brewPath = fixture.path

        // Appearance: the five modes parse from their raw strings, unknown/legacy values fall back
        // to System, and each maps to the expected underlying scheme + Papery theme selection.
        precondition(AppearanceMode("System") == .system && AppearanceMode("Light") == .light && AppearanceMode("Dark") == .dark)
        precondition(AppearanceMode("Papery Light") == .paperyLight && AppearanceMode("Papery Dark") == .paperyDark)
        precondition(AppearanceMode("nonsense") == .system, "Unknown appearance must fall back to System")
        precondition(AppearanceMode.system.underlyingScheme == nil)
        precondition(AppearanceMode.paperyLight.underlyingScheme == .light && AppearanceMode.paperyDark.underlyingScheme == .dark)
        precondition(AppearanceMode.paperyLight.isPapery && AppearanceMode.paperyDark.isDarkPaper && !AppearanceMode.light.isPapery)
        precondition(Theme.resolve(.paperyLight, systemIsDark: false).usesMaterial == false)
        precondition(Theme.resolve(.paperyDark, systemIsDark: false).usesMaterial == false)
        precondition(Theme.resolve(.system, systemIsDark: true).usesMaterial == true)
        model.appearance = "Papery Dark"
        precondition(model.appearanceMode == .paperyDark && model.preferredScheme == .dark)
        model.appearance = "System"
        precondition(model.preferredScheme == nil)

        func package(_ token: String) -> InstalledPackage {
            InstalledPackage(token: token, name: token, detail: "Fixture", version: "1", kind: "Formula")
        }
        let success = package("success"), failure = package("fail"), slow = package("slow")
        model.packages = [success, failure, slow]
        model.uninstallCandidate = success
        precondition(!model.busy) // Selecting a package must not start removal.
        model.uninstallCandidate = nil
        precondition(model.packages.count == 3) // Cancelling selection is harmless.
        model.uninstall(success)
        precondition(model.busy && model.uninstallCandidate == nil)
        model.uninstall(failure) // Conflicting clicks must be ignored.
        pump { !model.busy }
        precondition(model.exitCode == 0 && !model.packages.contains(success))
        precondition(model.output.contains("--formula\nsuccess") && !model.output.contains("--formula\nfail"))
        model.uninstall(failure)
        pump { !model.busy }
        precondition(model.exitCode == 1 && model.failed && model.packages.contains(failure))
        precondition(model.output.contains("Dependency prevents removal"))
        model.uninstall(slow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.stop() }
        pump { !model.busy }
        precondition(model.status == "Cancelled" && model.packages.contains(slow))

        // Install: confirmation selection doesn't launch; install runs the right typed arguments;
        // already-installed results are guarded; concurrent installs are ignored.
        let newFormula = SearchResult(token: "ripgrep", name: "ripgrep", detail: "Search tool", version: "14.1", kind: "Formula", installed: false)
        let newCask = SearchResult(token: "iterm2", name: "iTerm2", detail: "Terminal", version: "3.5", kind: "App", installed: false)
        let already = SearchResult(token: "wget", name: "wget", detail: "", version: "1", kind: "Formula", installed: true)
        precondition(newFormula.installArguments == ["install", "--formula", "ripgrep"])
        precondition(newCask.installArguments == ["install", "--cask", "iterm2"])
        model.searchResults = [newFormula, newCask, already]
        model.installCandidate = newFormula
        precondition(!model.busy)                          // selecting a candidate must not launch
        model.install(already)                             // already-installed guard: no launch
        precondition(!model.busy)
        model.install(newFormula)
        precondition(model.busy && model.installCandidate == nil)
        model.install(newCask)                             // concurrent install ignored
        // install() triggers an auto-refresh (a second brew command) on success, which resets the
        // console; wait for the result to reflect installed AND the model to be idle. The successful
        // installed-state flip proves the install command completed with exit 0.
        pump { !model.busy && model.searchResults.first { $0.token == "ripgrep" }?.installed == true }
        precondition(model.inventoryStale && model.updatesStale)
        precondition(!model.searchResults.first { $0.token == "iterm2" }!.installed)  // concurrent install was ignored
        print("PASS: install selection/guard, typed install arguments, concurrency, installed-state update")

        for action in BrewAction.all {
            model.run(action)
            pump { !model.busy }
            precondition(model.command == "brew " + action.command)
            precondition(model.output.components(separatedBy: "$ brew ").count == 2, "Unexpected follow-up command")
            precondition(!model.output.contains("\n\n\n"), "Excess blank lines")
        }
        print("PASS: all six maintenance buttons run only their named command; compact output")
        print("PASS: uninstall selection/cancel, launch, concurrency guard, success, failure retention, Stop")

        // Status-line column reset: when brew's final output does NOT end in a newline (so the
        // emulator's cursor is parked mid-line), the synthetic "[time] Succeeded · Exit 0" line must
        // still start at column 0, not be indented to that stale column. (Regression for the console
        // screenshot where "Succeeded · Exit 0" was pushed far to the right after `brew outdated`.)
        let noNewline = folder.appendingPathComponent("no-newline-brew")
        try """
        #!/bin/sh
        printf 'No changes to make.'
        exit 0
        """.write(to: noNewline, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: noNewline.path)
        model.brewPath = noNewline.path
        model.run(BrewAction(command: "outdated", title: "Outdated", detail: "", icon: ""))
        pump { !model.busy }
        let statusLine = model.output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).first { $0.contains("Succeeded · Exit 0") } ?? ""
        precondition(statusLine.hasPrefix("["),
                     "Status line must start at column 0 (begin with the '[time]' bracket), got: '\(statusLine)'")
        precondition(!statusLine.hasPrefix(" "),
                     "Status line must not be indented to brew's stale cursor column: '\(statusLine)'")
        print("PASS: completion status line starts at column 0 even when brew output has no trailing newline")

        // Synthetic SUMMARY line column reset (regression for v1.28.2): after a command finishes,
        // the completion handler appends the "[time] Succeeded · Exit 0\n" status line. A bare LF
        // preserves the column (correct terminal behaviour), so the emulator cursor is now parked at
        // that line's stale column. The app's own result-summary line that follows (e.g. checkUpdates'
        // "N available updates in current definitions.") must reset to column 0 with a leading CR,
        // not inherit the stale column. (Regression for the screenshots where "0 available updates…",
        // "Loaded N installed Homebrew packages.", and "Found N installable packages…" were pushed
        // far to the right.)
        let updatesFixture = folder.appendingPathComponent("updates-brew")
        try """
        #!/bin/sh
        printf '%s' '{"formulae":[],"casks":[]}'
        exit 0
        """.write(to: updatesFixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updatesFixture.path)
        model.brewPath = updatesFixture.path
        model.checkUpdates()
        pump { !model.busy && !model.checkingUpdates }
        let summaryLine = model.output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).first { $0.contains("available updates in current definitions.") } ?? ""
        precondition(!summaryLine.isEmpty, "Expected the 'available updates' summary line in the console")
        precondition(summaryLine.hasPrefix("0 available updates"),
                     "Summary line must start at column 0, got: '\(summaryLine)'")
        precondition(!summaryLine.hasPrefix(" "),
                     "Summary line must not be indented to the status line's stale cursor column: '\(summaryLine)'")
        model.brewPath = fixture.path
        print("PASS: synthetic summary line starts at column 0 after the completion status line")

        // Interactive [y/n] prompt: a fake brew that prints the ask-mode prompt then reads one char
        // from its TTY. The model must arm awaitingInput on the prompt line, answering "y" must let
        // it proceed to exit 0, and the prompt must NOT re-arm on the echoed answer / later output.
        let asker = folder.appendingPathComponent("ask-brew")
        try """
        #!/usr/bin/env ruby
        require 'io/console'
        STDOUT.sync = true
        puts '==> Upgrading 1 outdated package:'
        puts 'demo 1.0 -> 2.0'
        puts '==> Do you want to proceed with the upgrade? [y/n]'
        c = STDIN.getch
        puts ''
        puts '==> Fetching downloads for: demo'
        puts '==> Downloading https://example.invalid/demo'
        exit(c == 'y' ? 0 : 1)
        """.write(to: asker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: asker.path)
        model.brewPath = asker.path
        model.run(BrewAction(command: "upgrade", title: "Upgrade", detail: "", icon: ""))
        // Wait for the prompt to be recognised.
        pump { model.awaitingInput }
        precondition(model.promptText.contains("[y/n]"), "Prompt label should be the [y/n] line, got: \(model.promptText)")
        // Answering must disarm immediately and send exactly one byte.
        model.answer(true)
        precondition(!model.awaitingInput, "Answering must disarm the prompt")
        model.answer(true)   // A second click after disarm must be a no-op (guarded).
        pump { !model.busy }
        precondition(model.exitCode == 0, "Answering yes should let the command proceed to exit 0")
        // After brew moved past the prompt, the bar must stay disarmed even though "[y/n]" text is
        // still present earlier in the buffer (the old bug re-armed on that stale tail).
        precondition(!model.awaitingInput, "Prompt must not re-arm after brew proceeds")
        precondition(model.output.contains("Fetching downloads"), "Should have continued past the prompt")

        // Answering "no" aborts (exit 1).
        model.run(BrewAction(command: "upgrade", title: "Upgrade", detail: "", icon: ""))
        pump { model.awaitingInput }
        model.answer(false)
        pump { !model.busy }
        precondition(model.exitCode == 1 && !model.awaitingInput, "Answering no should abort (exit 1)")
        print("PASS: interactive [y/n] prompt arms once, answers via PTY, and does not re-arm")

        // Recovery flow: a fake brew that fails a `upgrade --cask postman` with the curl-56 resume
        // signature. The model must (1) set `recovery` with the extracted token on the failure, and
        // (2) on performRecovery run `cleanup postman` first, then re-run the original upgrade.
        // A marker file lets the fake brew succeed on the *second* upgrade so the retry ends clean.
        let marker = folder.appendingPathComponent("retry-marker")
        let resumeBrew = folder.appendingPathComponent("resume-brew")
        try """
        #!/bin/sh
        printf '%s\\n' "$@"
        if [ "$1" = "cleanup" ]; then exit 0; fi
        if [ "$1" = "upgrade" ]; then
          if [ -f "\(marker.path)" ]; then
            printf '==> Upgrading postman\\n'; exit 0
          fi
          touch "\(marker.path)"
          printf "Error: Download failed on Cask 'postman' with message: Download failed\\n" >&2
          printf "curl: (56) HTTP server doesn't seem to support byte ranges. Cannot resume.\\n" >&2
          exit 1
        fi
        exit 0
        """.write(to: resumeBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resumeBrew.path)
        model.brewPath = resumeBrew.path
        model.recovery = nil
        // Run a maintenance command (`brew upgrade`) that fails with the curl-56 resume signature.
        model.run(BrewAction(command: "upgrade", title: "Upgrade", detail: "", icon: ""))
        pump { !model.busy }
        precondition(model.failed && model.exitCode == 1, "First upgrade should fail")
        guard let rec = model.recovery else { preconditionFailure("A resume failure must offer recovery") }
        precondition(rec.kind == .resumableDownload, "Wrong recovery kind: \(rec.kind)")
        precondition(rec.token == "postman" && rec.isCask == true, "Recovery token/kind wrong: \(String(describing: rec.token))")
        // Retry: clears the cache (cleanup postman), then re-runs the original upgrade, which now
        // succeeds (marker present). Recovery is cleared once the retry starts.
        model.performRecovery()
        precondition(model.recovery == nil, "Retry must clear the recovery offer")
        pump { !model.busy }
        precondition(model.output.contains("cleanup\npostman"), "Retry should run `brew cleanup postman` first")
        precondition(model.exitCode == 0, "Re-run after cache clear should succeed")
        precondition(model.recovery == nil, "A successful retry leaves no recovery offer")
        // Guard: performRecovery is a no-op when there is no recovery offer.
        model.performRecovery()
        precondition(!model.busy, "No recovery → retry does nothing")
        // dismissRecovery clears the offer without running anything.
        model.recovery = RecoveryHint(kind: .resumableDownload, token: "x", isCask: false)
        model.dismissRecovery()
        precondition(model.recovery == nil && !model.busy, "Dismiss clears the offer without acting")
        print("PASS: resumable-download recovery detects token, clears cache, re-runs, and clears the offer")

        // Stale-app-artifact recovery: a fake brew that fails `upgrade --cask whatsapp` with the
        // "already an App at" error, then succeeds when re-run with `--force`. The model must set
        // recovery (kind .staleAppArtifact, token whatsapp), and performRecovery re-runs the exact
        // command with --force appended.
        let forceMarker = folder.appendingPathComponent("force-marker")
        let staleBrew = folder.appendingPathComponent("stale-brew")
        try """
        #!/bin/sh
        printf '%s\\n' "$@"
        if [ "$1" = "upgrade" ]; then
          for a in "$@"; do [ "$a" = "--force" ] && { printf '==> Upgrading whatsapp\\n'; exit 0; }; done
          printf "==> Upgrading whatsapp\\n"
          printf "Error: whatsapp: It seems there is already an App at '/opt/homebrew/Caskroom/whatsapp/26.38.20/WhatsApp.app'.\\n" >&2
          exit 1
        fi
        exit 0
        """.write(to: staleBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staleBrew.path)
        _ = forceMarker  // reserved for future use; kept for symmetry
        model.brewPath = staleBrew.path
        model.recovery = nil
        model.run(BrewAction(command: "upgrade", title: "Upgrade", detail: "", icon: ""))
        pump { !model.busy }
        precondition(model.failed && model.exitCode == 1, "Stale-artifact upgrade should fail first")
        guard let stale = model.recovery else { preconditionFailure("A stale-artifact failure must offer recovery") }
        precondition(stale.kind == .staleAppArtifact, "Wrong recovery kind: \(stale.kind)")
        precondition(stale.token == "whatsapp" && stale.isCask == true, "Stale token/kind wrong: \(String(describing: stale.token))")
        model.performRecovery()
        precondition(model.recovery == nil, "Force retry must clear the recovery offer")
        pump { !model.busy }
        precondition(model.output.contains("--force"), "Force retry should re-run the command with --force")
        precondition(model.exitCode == 0, "Re-run with --force should succeed")
        precondition(model.recovery == nil, "A successful force retry leaves no recovery offer")
        print("PASS: stale-app-artifact recovery detects token, force-retries, and clears the offer")

        // Feature 4 — Brewfile export arguments must NOT include the removed `--describe` switch
        // (current Homebrew rejects it). Descriptions are the default; export stays force + file.
        let dumpArgs = BrewModel.brewfileDumpArguments(path: "/tmp/Brewfile")
        precondition(dumpArgs == ["bundle", "dump", "--force", "--file=/tmp/Brewfile"], "Bad dump args: \(dumpArgs)")
        precondition(!dumpArgs.contains("--describe"), "--describe is disabled in current Homebrew and must not be passed")
        print("PASS: Brewfile dump arguments are force + file only (no disabled --describe)")

        // Feature 4 — Brewfile restore: a fake brew that echoes its args and exits 0. A confirmed
        // restore must run `brew bundle install --file=<path>`; cancel must run nothing.
        let bundleBrew = folder.appendingPathComponent("bundle-brew")
        try """
        #!/bin/sh
        printf '%s\\n' "$@"
        exit 0
        """.write(to: bundleBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundleBrew.path)
        model.brewPath = bundleBrew.path
        let brewfile = folder.appendingPathComponent("Brewfile")
        try "brew \"wget\"\n".write(to: brewfile, atomically: true, encoding: .utf8)
        // cancelRestoreBrewfile clears the candidate without running.
        model.brewfileRestoreCandidate = brewfile
        model.cancelRestoreBrewfile()
        precondition(model.brewfileRestoreCandidate == nil && !model.busy, "Cancel restore runs nothing")
        // confirmRestoreBrewfile runs bundle install with the chosen file.
        model.brewfileRestoreCandidate = brewfile
        model.confirmRestoreBrewfile()
        precondition(model.brewfileRestoreCandidate == nil, "Confirm clears the candidate")
        pump { !model.busy }
        precondition(model.exitCode == 0, "Restore should succeed")
        precondition(model.output.contains("bundle\ninstall\n--file=\(brewfile.path)"), "Restore must run bundle install with the file: \(model.output)")
        precondition(model.inventoryStale && model.updatesStale, "Restore marks inventory + updates stale")
        // Guard: confirm with no candidate does nothing.
        model.confirmRestoreBrewfile()
        precondition(!model.busy, "No candidate → confirm does nothing")
        print("PASS: Brewfile restore runs bundle install with chosen file; cancel/no-candidate are no-ops")

        // Feature 2 — fetchInfo: a fake brew that emits a formula info payload. The model must set
        // infoTarget immediately, then populate packageInfo from the parsed JSON.
        let infoBrew = folder.appendingPathComponent("info-brew")
        try #"""
        #!/bin/sh
        # Args land on stderr echo is skipped; emit JSON to stdout (captured to the info file).
        cat <<'JSON'
        {"formulae":[{"name":"wget","full_name":"wget","desc":"Internet file retriever","homepage":"https://www.gnu.org/software/wget/","versions":{"stable":"1.25.0"},"dependencies":["openssl@3"],"installed":[{"version":"1.25.0","installed_size":2097152}]}],"casks":[]}
        JSON
        exit 0
        """#.write(to: infoBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: infoBrew.path)
        model.brewPath = infoBrew.path
        model.fetchInfo(token: "wget", kind: "Formula", id: "Formula:wget")
        precondition(model.infoTarget == "Formula:wget" && model.infoLoading, "fetchInfo arms target + loading immediately")
        pump { !model.busy }
        precondition(!model.infoLoading, "info loading clears when done")
        precondition(model.packageInfo?.name == "wget", "packageInfo should be populated: \(String(describing: model.packageInfo))")
        precondition(model.packageInfo?.installSize == "2.0 MB" && model.packageInfo?.dependencies == ["openssl@3"], "info fields parsed")
        // dismissInfo clears everything.
        model.dismissInfo()
        precondition(model.infoTarget == nil && model.packageInfo == nil, "dismissInfo clears state")
        // Guard: an invalid token is rejected without running.
        model.fetchInfo(token: "bad;rm", kind: "Formula", id: "x")
        precondition(model.infoError != nil && !model.busy, "Invalid token rejected")
        print("PASS: fetchInfo arms target, populates packageInfo, dismiss + invalid-token guards")

        // Feature 1 — updateCount from a check. A fake brew emitting an outdated payload with one
        // cask updates the count.
        let outdatedBrew = folder.appendingPathComponent("outdated-brew")
        try #"""
        #!/bin/sh
        cat <<'JSON'
        {"formulae":[{"name":"wget","installed_versions":["1.0"],"current_version":"2.0","pinned":false}],"casks":[]}
        JSON
        exit 0
        """#.write(to: outdatedBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outdatedBrew.path)
        model.brewPath = outdatedBrew.path
        model.updateCount = 0
        model.checkUpdates()
        pump { !model.busy }
        precondition(model.updateCount == 1, "checkUpdates should set updateCount from results: \(model.updateCount)")
        print("PASS: updateCount reflects the latest outdated check")

        // normalizeLineBreaks (non-PTY stair-step fix): bare LF becomes CR+LF so each line starts at
        // column 0, while an existing CRLF is NOT doubled and a lone CR is left intact. (This is what
        // flush applies to the plain-pipe path so brew's `==> Auto-updating…` preamble stops marching
        // right.) Pure/static — assert the exact transformation.
        precondition(BrewModel.normalizeLineBreaks("a\nb\nc") == "a\r\nb\r\nc", "bare LF must gain a CR")
        precondition(BrewModel.normalizeLineBreaks("a\r\nb") == "a\r\nb", "existing CRLF must not be doubled")
        precondition(BrewModel.normalizeLineBreaks("a\rb") == "a\rb", "lone CR must be left intact")
        precondition(BrewModel.normalizeLineBreaks("") == "", "empty input stays empty")
        // End-to-end: feed brew's real non-PTY preamble through the emulator the way flush does for a
        // JSON command (bare LF normalised). Every `==>` line must sit at column 0 (no stair-step).
        var nonpty = TerminalEmulator()
        nonpty.feed(BrewModel.normalizeLineBreaks("==> Auto-updating Homebrew...\n==> Auto-updated Homebrew!\n==> Updated Homebrew from a to b.\n"))
        let nonptyLines = nonpty.render().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        precondition(nonptyLines[1] == "==> Auto-updated Homebrew!",
                     "non-PTY preamble row 1 must start at col 0: '\(nonptyLines[1])'")
        precondition(nonptyLines[2] == "==> Updated Homebrew from a to b.",
                     "non-PTY preamble row 2 must start at col 0: '\(nonptyLines[2])'")
        print("PASS: non-PTY line-break normalization keeps brew's plain-pipe lines at column 0")

        // FLUSH-LEVEL non-PTY regression (the actual screenshot bug): checkUpdates runs
        // `brew outdated --json=v2` with a standardOutputFile, so usingPTY=false. brew's auto-update
        // preamble goes to STDERR (→ console) as progressive bare-LF lines while the JSON goes to
        // STDOUT (→ the capture file). Those `==>` lines must land at column 0, not stair-step. This
        // drives the real flush() path end-to-end (not just the pure helper).
        let preambleBrew = folder.appendingPathComponent("preamble-brew")
        try """
        #!/bin/sh
        printf '==> Auto-updating Homebrew...\\n' >&2
        printf '==> Auto-updated Homebrew!\\n' >&2
        printf '==> Updated Homebrew from a to b.\\n' >&2
        printf '%s' '{"formulae":[],"casks":[]}'
        exit 0
        """.write(to: preambleBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preambleBrew.path)
        model.brewPath = preambleBrew.path
        model.checkUpdates()
        pump { !model.busy && !model.checkingUpdates }
        let consoleLines = model.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let autoUpdated = consoleLines.first { $0.contains("Auto-updated Homebrew!") } ?? ""
        let updatedFrom = consoleLines.first { $0.contains("Updated Homebrew from") } ?? ""
        precondition(autoUpdated == "==> Auto-updated Homebrew!",
                     "non-PTY preamble line must start at col 0 via flush, got: '\(autoUpdated)'")
        precondition(updatedFrom == "==> Updated Homebrew from a to b.",
                     "non-PTY preamble line must start at col 0 via flush, got: '\(updatedFrom)'")
        model.brewPath = fixture.path
        print("PASS: non-PTY flush path keeps brew's stderr `==>` preamble at column 0")

        print("PASS: UninstallTests")
    }
    static func pump(_ done: () -> Bool) {
        let end = Date().addingTimeInterval(12)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done(), "Uninstall timeout")
    }
}
