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
        for action in BrewAction.all {
            model.run(action)
            pump { !model.busy }
            precondition(model.command == "brew " + action.command)
            precondition(model.output.components(separatedBy: "$ brew ").count == 2, "Unexpected follow-up command")
            precondition(!model.output.contains("\n\n\n"), "Excess blank lines")
        }
        print("PASS: all six maintenance buttons run only their named command; compact output")
        print("PASS: uninstall selection/cancel, launch, concurrency guard, success, failure retention, Stop")
    }
    static func pump(_ done: () -> Bool) {
        let end = Date().addingTimeInterval(12)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done(), "Uninstall timeout")
    }
}
