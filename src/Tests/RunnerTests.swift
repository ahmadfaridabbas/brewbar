import Foundation
import Darwin

@main struct RunnerTests {
    static func main() {
        let updatesFixture = Data(#"{"formulae":[{"name":"jpeg-xl","installed_versions":["0.12.0"],"current_version":"0.12.0_1","pinned":false},{"name":"openexr","installed_versions":["3.4.15_1"],"current_version":"3.5.0","pinned":false}],"casks":[{"name":"test-app","installed_versions":"1.0","current_version":"2.0"}]}"#.utf8)
        let updates = try! PackageUpdate.parse(updatesFixture)
        precondition(updates.count == 3)
        let jpeg = updates.first { $0.name == "jpeg-xl" }!
        precondition(jpeg.currentVersion == "0.12.0_1" && jpeg.installedVersions == ["0.12.0"])
        precondition(jpeg.arguments == ["upgrade", "--formula", "jpeg-xl"])
        precondition(updates.first { $0.kind == "App" }!.arguments == ["upgrade", "--cask", "test-app"])
        precondition(try! PackageUpdate.parse(Data(#"{"formulae":[],"casks":[]}"#.utf8)).isEmpty)
        do { _ = try PackageUpdate.parse(Data("{}".utf8)); preconditionFailure("Invalid update data accepted") } catch {}
        // Regression: brew prints "==> Downloading Homebrew API data" to stdout before the JSON
        // when its API cache is cold. That preamble must not break parsing (Exit 0 but read error).
        let noisy = Data(("==> Downloading Homebrew API data\n" + #"{"formulae":[{"name":"wget","installed_versions":["1.0"],"current_version":"2.0","pinned":false}],"casks":[]}"# + "\n").utf8)
        precondition(try! PackageUpdate.parse(noisy).count == 1, "Progress preamble broke update parsing")
        let noisyInstalled = Data(("==> Downloading Homebrew API data\n" + #"{"formulae":[{"name":"wget","full_name":"wget","desc":"d","installed":[{"version":"1.0"}]}],"casks":[]}"#).utf8)
        precondition(try! InstalledPackage.parse(noisyInstalled).count == 1, "Progress preamble broke installed parsing")
        print("PASS: screenshot revision and version updates, formula/cask routing, empty/malformed updates")
        let runner = CommandRunner()
        var received = ""
        var done = false
        runner.run(executable: "/bin/sh", arguments: ["-c", "printf 'stdout'; printf 'stderr' >&2; exit 7"], environment: ProcessInfo.processInfo.environment) { data in
            received += String(decoding: data, as: UTF8.self)
        } completion: { code, stopped in
            precondition(code == 7 && !stopped && received == "stdoutstderr", "Streams or exit status incorrect")
            done = true
        }
        pump { done }
        let cancelled = CommandRunner()
        done = false
        let start = Date()
        cancelled.run(executable: "/bin/sh", arguments: ["-c", "sleep 30 & wait"], environment: ProcessInfo.processInfo.environment) { _ in } completion: { code, stopped in
            precondition(stopped && code != 0 && Date().timeIntervalSince(start) < 10, "Cancellation failed")
            done = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { cancelled.cancel() }
        pump { done }
        let missing = CommandRunner()
        done = false
        missing.run(executable: "/does/not/exist", arguments: [], environment: [:]) { _ in } completion: { code, _ in
            precondition(code == 127); done = true
        }
        pump { done }
        let (_, env) = BrewEnvironment.resolve(["PATH": "/custom/bin:/usr/bin"])
        precondition(env["PATH"]!.hasPrefix("/opt/homebrew/bin:/opt/homebrew/sbin:/custom/bin"))
        precondition(env["NONINTERACTIVE"] == "1")
        let fixture = Data(#"{"formulae":[{"name":"wget","full_name":"wget","desc":"Downloader","installed":[{"version":"1.0"},{"version":"2.0"}]}],"casks":[{"token":"sample","full_token":"vendor/tap/sample","name":["Sample App"],"installed":"3.0"},{"token":"absent","installed":null}]}"#.utf8)
        let packages = try! InstalledPackage.parse(fixture)
        precondition(packages.count == 2)
        let app = packages.first { $0.kind == "App" }!
        precondition(app.uninstallArguments == ["uninstall", "--cask", "vendor/tap/sample"])
        precondition(packages.first { $0.kind == "Formula" }!.version == "1.0, 2.0")
        precondition(!InstalledPackage(token: "--force", name: "bad", detail: "", version: "", kind: "Formula").canUninstall)
        do { _ = try InstalledPackage.parse(Data("bad JSON".utf8)); preconditionFailure("Malformed JSON accepted") } catch {}
        precondition(try! InstalledPackage.parse(Data(#"{"formulae":[],"casks":[]}"#.utf8)).isEmpty)

        // SearchResult: brew info --json=v2 enrichment yields kind, desc, version, and installed-state.
        let searchFixture = Data(#"""
        {"formulae":[{"name":"wget","full_name":"wget","desc":"Internet file retriever","versions":{"stable":"1.25.0"},"installed":[]},
                     {"name":"node","full_name":"node","desc":"JS runtime","versions":{"stable":"22.14.0"},"installed":[{"version":"22.14.0"}]}],
         "casks":[{"token":"google-chrome","full_token":"google-chrome","name":["Google Chrome"],"desc":"Web browser","version":"154.0","installed":"154.0"},
                  {"token":"iterm2","full_token":"iterm2","name":["iTerm2"],"desc":"Terminal","version":"3.5","installed":null}]}
        """#.utf8)
        let results = try! SearchResult.parse(searchFixture)
        precondition(results.count == 4)
        let wget = results.first { $0.token == "wget" }!
        precondition(wget.kind == "Formula" && !wget.installed && wget.version == "1.25.0")
        precondition(wget.installArguments == ["install", "--formula", "wget"])
        precondition(results.first { $0.token == "node" }!.installed)          // installed[] non-empty
        let chrome = results.first { $0.token == "google-chrome" }!
        precondition(chrome.kind == "App" && chrome.installed && chrome.installArguments == ["install", "--cask", "google-chrome"])
        precondition(!results.first { $0.token == "iterm2" }!.installed)       // installed == null
        // Progress preamble tolerance on the info stage too.
        let noisySearch = Data(("==> Downloading Homebrew API data\n" + #"{"formulae":[{"name":"jq","versions":{"stable":"1.7"},"installed":[]}],"casks":[]}"#).utf8)
        precondition(try! SearchResult.parse(noisySearch).count == 1)
        // Invalid token is rejected by `valid`.
        precondition(!SearchResult(token: "--build-from-source", name: "x", detail: "", version: "1", kind: "Formula", installed: false).valid)
        // brew search plain-text token extraction skips headers/warnings/blank lines.
        let tokens = SearchResult.searchTokens("==> Formulae\nwget\nwget2\n\nWarning: nothing\nnode\n")
        precondition(tokens == ["wget", "wget2", "node"], "Unexpected search tokens: \(tokens)")
        print("PASS: search result parsing (kind, version, installed-state), install arguments, token extraction")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let separated = CommandRunner()
        done = false; received = ""
        separated.run(executable: "/bin/sh", arguments: ["-c", "printf '{json}'; printf 'warning' >&2"], environment: [:], standardOutputFile: file) { data in
            received += String(decoding: data, as: UTF8.self)
        } completion: { code, _ in
            precondition(code == 0 && received == "warning")
            precondition((try! String(contentsOf: file, encoding: .utf8)) == "{json}")
            done = true
        }
        pump { done }
        print("PASS: installed package parsing, typed uninstall arguments, invalid token rejection, separate JSON stdout")
        print("PASS: merged stdout/stderr, exit status, process-group cancellation, launch failure, environment")
    }
    static func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done(), "Test timeout")
    }
}
