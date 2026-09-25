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
    }
    static func pump(_ done: () -> Bool) {
        let end = Date().addingTimeInterval(12)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done(), "Uninstall timeout")
    }
}
