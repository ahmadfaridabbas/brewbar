import Foundation
import Darwin

@main struct RunnerTests {
    static func main() {
        let updatesFixture = Data(#"{"formulae":[{"name":"jpeg-xl","installed_versions":["0.12.0"],"current_version":"0.12.0_1","pinned":false},{"name":"openexr","installed_versions":["3.4.15_1"],"current_version":"3.5.0","pinned":false}],"casks":[{"name":"test-app","installed_versions":"1.0","current_version":"2.0"}]}"#.utf8)
        let updates = try! PackageUpdate.parse(updatesFixture)
        precondition(updates.count == 3)
        let jpeg = updates.first { $0.name == "jpeg-xl" }!
        precondition(jpeg.currentVersion == "0.12.0_1" && jpeg.installedVersions == ["0.12.0"])
        precondition(jpeg.arguments == ["upgrade", "--formula", "jpeg-xl"], "Formula upgrade must NOT force")
        // Casks get --force so a targeted single-package upgrade doesn't dead-end on a stale .app
        // ("It seems there is already an App at …"), matching brew's bare-upgrade behavior.
        precondition(updates.first { $0.kind == "App" }!.arguments == ["upgrade", "--cask", "--force", "test-app"],
                     "Targeted cask upgrade must pass --force")
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

        // Multi-word Search & Install fix: brew matches lowercase tokens (no spaces/capitals), so a
        // human query like "Tinycast Beta" must (1) search brew on the single most distinctive word,
        // and (2) filter enriched results by the full query against token+name.
        // (1) distinctiveTerm picks the longest brew-safe word, lowercased.
        precondition(SearchResult.distinctiveTerm("tinycast Beta") == "tinycast", "distinctiveTerm should pick the longest word")
        precondition(SearchResult.distinctiveTerm("the chrome") == "chrome", "longest word wins over a shorter one")
        precondition(SearchResult.distinctiveTerm("wget") == "wget", "single-word query passes through")
        precondition(SearchResult.distinctiveTerm("  ") == nil, "blank query yields no term")
        precondition(SearchResult.distinctiveTerm("Google Chrome") == "google", "equal-length words resolve to the first")
        // (2) matches: every query word must appear in token+name (case-insensitive substring).
        let tinycastBeta = SearchResult(token: "abue-ammar/tinycast/tinycast@beta", name: "Tinycast Beta", detail: "", version: "0.1", kind: "App", installed: false)
        let tinycast     = SearchResult(token: "abue-ammar/tinycast/tinycast",      name: "Tinycast",      detail: "", version: "0.1", kind: "App", installed: false)
        let tinymist     = SearchResult(token: "tinymist",                          name: "tinymist",      detail: "", version: "0.1", kind: "Formula", installed: false)
        precondition(tinycastBeta.matches(query: "tinycast Beta"), "Tinycast Beta must survive the multi-word filter")
        precondition(!tinycast.matches(query: "tinycast Beta"), "plain Tinycast lacks 'beta' → filtered out")
        precondition(!tinymist.matches(query: "tinycast Beta"), "tinymist must not match a tinycast query")
        precondition(tinycast.matches(query: "tinycast"), "single-word query keeps a token-substring match")
        precondition(tinymist.matches(query: "tiny"), "substring match on name/token")
        // The whole tinycast set filtered by the multi-word query yields exactly Tinycast Beta.
        precondition([tinycastBeta, tinycast, tinymist].filter { $0.matches(query: "tinycast Beta") } == [tinycastBeta],
                     "Multi-word filter should resolve to exactly the Beta package")
        print("PASS: search result parsing (kind, version, installed-state), install arguments, token extraction")

        // Download progress parser: brew's `==> Downloading <url>` starts a bar, the `#### NN.N%`
        // line advances it, and 100%/`Downloaded to:`/a following `==>` step ends it.
        typealias PAction = DownloadProgressParser.Action
        func parse(_ line: String) -> PAction { DownloadProgressParser.parse(line: line) }
        // Start: a real http(s) URL begins a download and extracts a readable file name.
        guard case .start(_, let dlName) = parse("==> Downloading https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin.zip")
        else { preconditionFailure("Downloading line should start a download") }
        precondition(dlName == "ChatGPT-darwin.zip", "Bad file name: \(dlName)")
        // Query strings and percent-encoding are stripped from the file name.
        precondition(DownloadProgressParser.fileName(fromURL:
            "https://release-assets.githubusercontent.com/x/y?rscd=attachment%3B+filename%3DHack-v3.003-ttf.zip&sig=abc")
            == "y", "File name should be the URL's last path component")
        precondition(DownloadProgressParser.fileName(fromURL:
            "https://example.com/downloads/Hack%20Nerd%20Font.zip") == "Hack Nerd Font.zip")
        // `Downloading from <mirror>` is a redirect notice, not a new file.
        precondition(parse("==> Downloading from https://mirror.example.com/file.zip") == .none)
        // brew's API cache preamble must not be treated as a file download.
        precondition(parse("==> Downloading Homebrew API data") == .none)
        // Progress frames.
        precondition(parse("####                                                                       6.8%") == .progress(fraction: 0.068))
        precondition(parse("################################                                          45.1%") == .progress(fraction: 0.451))
        precondition(parse("#=#=#") == .none, "curl's warm-up frame has no percentage")
        // 100% ends the bar.
        precondition(parse("######################################################################## 100.0%") == .finish)
        // Settled/lingering-file lines end the bar.
        precondition(parse("Downloaded to: /Users/x/Library/Caches/Homebrew/downloads/abc--file.zip") == .finish)
        precondition(parse("Already downloaded: /Users/x/Library/Caches/Homebrew/downloads/abc--file.zip") == .finish)
        // A following non-download step ends the bar.
        precondition(parse("==> Installing Cask chatgpt") == .finish)
        // Unrelated lines leave the bar untouched.
        precondition(parse("chatgpt 26.917.71314 -> 26.924.20706") == .none)
        precondition(parse("") == .none)
        // DownloadProgress derives bytes and a readable summary from fraction + total.
        var dp = DownloadProgress(fileName: "f.zip", fraction: 0.5, totalBytes: nil)
        precondition(dp.summary == "50%", "Without a size the summary is just the percentage: \(dp.summary)")
        dp.totalBytes = 27_400_000
        precondition(dp.downloadedBytes == 13_700_000)
        precondition(dp.summary == "13.1 MB of 26.1 MB · 50%", "Unexpected summary: \(dp.summary)")
        precondition(DownloadProgress.format(512) == "512 bytes")
        precondition(DownloadProgress.format(2048) == "2.0 KB")

        // brew's parallel-queue byte counter drives the bar with exact numbers (no HEAD needed).
        guard case .bytes(let rcv, let tot, let bname, let bdone) =
            parse("⠿ Cask readdle-spark (3.31.3.141073) ##########   Downloading 263.1MB/373.1MB")
        else { preconditionFailure("byte counter should yield .bytes") }
        precondition(bname == "readdle-spark", "Bad cask name: \(String(describing: bname))")
        precondition(rcv == Int64((263.1 * 1024 * 1024).rounded()))
        precondition(tot == Int64((373.1 * 1024 * 1024).rounded()))
        precondition(bdone == false, "in-progress byte counter should not be complete")
        // A NAMED `Downloaded X/X` (received == total) stays a .bytes marked complete, so the parallel
        // block can keep that row at 100% until every download finishes (option b).
        guard case .bytes(_, _, let dname, let ddone) =
            parse("✓ Cask readdle-spark (3.31.3.141073)          Downloaded 373.1MB/373.1MB")
        else { preconditionFailure("named completed counter should yield .bytes(complete)") }
        precondition(dname == "readdle-spark" && ddone == true, "named completion should be complete")
        // A byte counter WITHOUT a Cask/Formula prefix still parses (name nil).
        guard case .bytes(_, _, let noName, _) = parse("Downloading 1.5GB/4.0GB") else { preconditionFailure("bytes w/o name") }
        precondition(noName == nil)
        // An UNNAMED completed counter ends the (single-download) bar.
        precondition(parse("Downloaded 4.0GB/4.0GB") == .finish)
        // applyExactBytes sets authoritative bytes + fraction, overriding any estimate.
        var ex = DownloadProgress(fileName: "spark.pkg", fraction: 0.2, totalBytes: 999)
        ex.applyExactBytes(received: 263_100_000, total: 373_100_000)
        precondition(ex.downloadedBytes == 263_100_000 && ex.totalBytes == 373_100_000)
        precondition(abs(ex.fraction - 0.705) < 0.01, "fraction from bytes wrong: \(ex.fraction)")
        precondition(DownloadProgressParser.bytes(value: "263.1", unit: "MB") == Int64((263.1 * 1024 * 1024).rounded()))
        precondition(DownloadProgressParser.bytes(value: "2", unit: "GB") == Int64(2) * 1024 * 1024 * 1024)
        print("PASS: download progress parsing (start/advance/finish), file-name extraction, byte summary")

        // AppUpdate (Phase 1): version parsing + strictly-newer comparison, tag normalization.
        precondition(AppUpdate.versionComponents("v1.26") == [1, 26])
        precondition(AppUpdate.versionComponents("1.26.1") == [1, 26, 1])
        precondition(AppUpdate.versionComponents("v1.26-beta") == [1, 26], "pre-release suffix should drop")
        precondition(AppUpdate.versionComponents("nightly").isEmpty, "non-numeric tag yields no components")
        precondition(AppUpdate.isNewer("v1.26", than: "1.25"), "1.26 > 1.25")
        precondition(AppUpdate.isNewer("1.26.1", than: "1.26"), "1.26.1 > 1.26")
        precondition(AppUpdate.isNewer("v2.0", than: "1.99"), "2.0 > 1.99")
        precondition(!AppUpdate.isNewer("1.25", than: "1.25"), "equal is not newer")
        precondition(!AppUpdate.isNewer("1.24", than: "1.25"), "older is not newer")
        precondition(!AppUpdate.isNewer("garbage", than: "1.25"), "unparseable candidate fails safe")
        precondition(!AppUpdate.isNewer("1.26", than: "garbage"), "unparseable current fails safe")
        // tag_name extraction from a GitHub releases/latest payload.
        let relJSON = Data(#"{"tag_name":"v1.26","name":"BrewBar 1.26","draft":false}"#.utf8)
        precondition(AppUpdate.tagName(fromLatestReleaseJSON: relJSON) == "v1.26")
        precondition(AppUpdate.displayVersion(fromTag: "v1.26") == "1.26")
        precondition(AppUpdate.tagName(fromLatestReleaseJSON: Data("{}".utf8)) == nil, "missing tag → nil")
        // Phase 2: checksum parsing + asset URL extraction + asset filename.
        let sums = AppUpdate.parseChecksums("abc123\n" + String(repeating: "a", count: 64) + "  BrewBar-1.27.zip\n")
        precondition(sums["BrewBar-1.27.zip"] == String(repeating: "a", count: 64), "checksum line should parse")
        precondition(AppUpdate.parseChecksums("nothex  X.zip").isEmpty, "non-64-hex should be ignored")
        precondition(AppUpdate.assetFileName(forTag: "v1.27") == "BrewBar-1.27.zip")
        let relWithAsset = Data(#"{"tag_name":"v1.27","assets":[{"name":"BrewBar-1.27.zip","browser_download_url":"https://example.invalid/BrewBar-1.27.zip"}]}"#.utf8)
        precondition(AppUpdate.zipAssetURL(fromLatestReleaseJSON: relWithAsset)?.absoluteString == "https://example.invalid/BrewBar-1.27.zip")
        precondition(AppUpdate.zipAssetURL(fromLatestReleaseJSON: Data(#"{"assets":[]}"#.utf8)) == nil, "no zip asset → nil")
        precondition(AppUpdate.fallbackZipURL(tag: "v1.27")?.absoluteString == "https://github.com/ahmadfaridabbas/brewbar/releases/download/v1.27/BrewBar-1.27.zip")
        print("PASS: app update version compare, tag parse, and fail-safe guards")

        // RecoveryHint: a resumable-download dead-end (curl-56 / "Cannot resume") is detected and the
        // affected package token + kind are extracted from brew's "Download failed on Cask 'x'" line.
        let curl56Output = """
        ==> Fetching downloads for: postman
        ✗ Cask postman (12.30.0)                             Downloading
        Error: Download failed on Cask 'postman' with message: Download failed: https://dl.pstmn.io/download/version/12.30.0/osx_arm64
        curl: (56) HTTP server doesn't seem to support byte ranges. Cannot resume.
        Error: postman: Download failed for postman.
        """
        guard let hint = RecoveryHintDetector.detect(in: curl56Output) else {
            preconditionFailure("curl-56 resume failure should be detected")
        }
        precondition(hint.kind == .resumableDownload, "curl-56 should be a resumable-download hint")
        precondition(hint.token == "postman", "Bad token: \(String(describing: hint.token))")
        precondition(hint.isCask == true, "postman is a cask")
        precondition(hint.message.contains("postman") && hint.message.contains("resuming"),
                     "Message should name the package and mention resuming: \(hint.message)")
        // A formula variant is recognised and flagged as not-a-cask.
        let formulaOutput = "Error: Download failed on Formula 'wget' with message: …\ncurl: (56) ... Cannot resume."
        let formulaHint = RecoveryHintDetector.detect(in: formulaOutput)
        precondition(formulaHint?.token == "wget" && formulaHint?.isCask == false, "Formula token/kind wrong")
        // The explicit "byte ranges" phrasing is enough even without the literal "curl: (56)".
        precondition(RecoveryHintDetector.detect(in: "Error: HTTP server doesn't seem to support byte ranges.") != nil)
        // A hint with no "Download failed on …" line still fires, just without a token.
        let noToken = RecoveryHintDetector.detect(in: "curl: (56) The requested URL returned error. Cannot resume.")
        precondition(noToken != nil && noToken?.token == nil, "Tokenless resume failure should still offer recovery")
        // Non-resume failures must NOT be offered a cache-clear.
        precondition(RecoveryHintDetector.detect(in: "curl: (56) Recv failure: Connection reset by peer") == nil,
                     "curl-56 without a resume phrase is not recoverable this way")
        precondition(RecoveryHintDetector.detect(in: "Error: Cask 'foo' is not installed.") == nil)
        precondition(RecoveryHintDetector.detect(in: "") == nil)
        print("PASS: recovery hint detection (curl-56 resume, formula/cask token, false-positive guards)")

        // Stale-app-artifact: a cask upgrade blocked by a leftover .app ("It seems there is already
        // an App at …") is detected as a distinct kind, with a --force-based recovery.
        let staleOutput = """
        ==> Upgrading whatsapp
          26.38.20 -> 26.39.12
        ==> Purging files for version 26.39.12 of Cask whatsapp
        Error: whatsapp: It seems there is already an App at '/opt/homebrew/Caskroom/whatsapp/26.38.20/WhatsApp.app'.
        """
        guard let staleHint = RecoveryHintDetector.detect(in: staleOutput) else {
            preconditionFailure("Stale-artifact failure should be detected")
        }
        precondition(staleHint.kind == .staleAppArtifact, "Should be a stale-artifact hint")
        precondition(staleHint.token == "whatsapp", "Bad stale token: \(String(describing: staleHint.token))")
        precondition(staleHint.isCask == true, "A stale-artifact failure is always a cask")
        precondition(staleHint.actionTitle == "Force Retry", "Stale hint uses a Force Retry action")
        precondition(staleHint.message.contains("whatsapp") && staleHint.message.lowercased().contains("force"),
                     "Stale message should name the package and mention force: \(staleHint.message)")
        // The stale-artifact phrase wins over an unrelated line, and a message without the phrase
        // is not mistaken for one.
        precondition(RecoveryHintDetector.detect(in: "Error: some other cask problem") == nil)
        print("PASS: stale-app-artifact detection (token, cask flag, force-retry action)")

        // PackageInfo: parse `brew info --json=v2 <token>` for a formula (homepage, deps, version,
        // size, caveats) and a cask (depends_on, no size), plus the homepage-validity guard.
        let formulaInfoJSON = Data(#"""
        {"formulae":[{"name":"wget","full_name":"wget","desc":"Internet file retriever","homepage":"https://www.gnu.org/software/wget/","versions":{"stable":"1.25.0"},"dependencies":["libidn2","openssl@3"],"installed":[{"version":"1.25.0","installed_size":4194304}],"caveats":"Some caveat text.\n"}],"casks":[]}
        """#.utf8)
        guard let wgetInfo = PackageInfo.parse(formulaInfoJSON) else { preconditionFailure("Formula info should parse") }
        precondition(wgetInfo.kind == "Formula" && wgetInfo.name == "wget", "Bad formula identity")
        precondition(wgetInfo.description == "Internet file retriever", "Bad desc: \(wgetInfo.description)")
        precondition(wgetInfo.homepage == "https://www.gnu.org/software/wget/" && wgetInfo.homepageIsValid, "Homepage should be valid")
        precondition(wgetInfo.version == "1.25.0", "Bad version: \(wgetInfo.version)")
        precondition(wgetInfo.dependencies == ["libidn2", "openssl@3"], "Bad deps: \(wgetInfo.dependencies)")
        precondition(wgetInfo.installSize == "4.0 MB", "Bad size: \(String(describing: wgetInfo.installSize))")
        precondition(wgetInfo.caveats == "Some caveat text.", "Caveats should be trimmed: \(String(describing: wgetInfo.caveats))")

        let caskInfoJSON = Data(#"""
        {"formulae":[],"casks":[{"token":"iterm2","full_token":"iterm2","name":["iTerm2"],"desc":"Terminal emulator","homepage":"https://iterm2.com/","version":"3.5.0","depends_on":{"formula":["something"],"cask":["xquartz"]}}]}
        """#.utf8)
        guard let itermInfo = PackageInfo.parse(caskInfoJSON) else { preconditionFailure("Cask info should parse") }
        precondition(itermInfo.kind == "App" && itermInfo.name == "iTerm2", "Bad cask identity")
        precondition(itermInfo.version == "3.5.0" && itermInfo.installSize == nil, "Cask has version, no size")
        precondition(itermInfo.dependencies == ["something", "xquartz"], "Bad cask deps: \(itermInfo.dependencies)")
        precondition(itermInfo.caveats == nil, "No caveats expected")
        // Preamble tolerance + guards.
        let noisyInfo = Data(("==> Downloading Homebrew API data\n" + String(data: formulaInfoJSON, encoding: .utf8)!).utf8)
        precondition(PackageInfo.parse(noisyInfo)?.name == "wget", "Preamble should not break info parsing")
        precondition(PackageInfo.parse(Data(#"{"formulae":[],"casks":[]}"#.utf8)) == nil, "Empty payload → nil")
        // Homepage validity guard: a non-http scheme or empty string is not openable.
        let badHome = PackageInfo(token: "x", name: "x", kind: "Formula", description: "", homepage: "javascript:alert(1)", version: "1", dependencies: [], installSize: nil, caveats: nil)
        precondition(!badHome.homepageIsValid, "Non-http homepage must be rejected")
        precondition(PackageInfo.formatBytes(0) == "—" && PackageInfo.formatBytes(512) == "512 B" && PackageInfo.formatBytes(1536) == "1.5 KB", "Byte formatting")
        print("PASS: package info parsing (formula deps/size/caveats, cask depends_on, homepage guard, byte format)")


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
