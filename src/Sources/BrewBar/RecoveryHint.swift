import Foundation

/// A recoverable failure that BrewBar can offer to fix with one click. Two flavours are covered:
///
/// 1. `.resumableDownload` — Homebrew's "resumable download" dead-end: when a partial file is left
///    in brew's download cache and the file's HTTP server does not honour byte-range (resume)
///    requests, curl aborts with `curl: (56) … Cannot resume`. brew retries once, hits the same
///    wall, and gives up. The fix is to clear the stale cached download so the next fetch starts
///    fresh (`brew cleanup <token>`, then re-run the command).
///
/// 2. `.staleAppArtifact` — a cask upgrade fails with `It seems there is already an App at '…'`
///    because a leftover `.app` from the previous version blocks the install. The fix is to re-run
///    the same command with `--force`, which tells brew to overwrite the existing artifact.
struct RecoveryHint: Equatable {
    /// The class of failure, which determines the message and the recovery action.
    enum Kind: Equatable {
        /// A stale partial download that can't be resumed; recover by clearing the cache.
        case resumableDownload
        /// A leftover app artifact blocking a cask upgrade; recover by forcing the command.
        case staleAppArtifact
    }

    /// The class of failure this hint represents.
    var kind: Kind
    /// The affected package token (e.g. `postman`), pulled from brew's
    /// `Download failed on Cask 'postman'` / `Formula 'wget'` line, or the `Error: <token>:` prefix
    /// of the stale-artifact message, when present.
    var token: String?
    /// Whether the affected package is a cask (vs. a formula). Nil when brew didn't say.
    var isCask: Bool?
    /// A short, user-facing explanation shown in the recovery bar.
    var message: String {
        let name = token.map { "“\($0)”" } ?? "this package"
        switch kind {
        case .resumableDownload:
            return "The download server for \(name) doesn't support resuming a partial file. "
                + "Clear the cached download and try again."
        case .staleAppArtifact:
            return "An older app for \(name) is still in place and is blocking the upgrade. "
                + "Retry with --force to overwrite it."
        }
    }

    /// The label for the recovery bar's primary button, tailored to the fix being offered.
    var actionTitle: String {
        switch kind {
        case .resumableDownload: return "Clear Cache & Retry"
        case .staleAppArtifact: return "Force Retry"
        }
    }

    /// The SF Symbol shown on the primary button.
    var actionSymbol: String {
        switch kind {
        case .resumableDownload: return "arrow.clockwise"
        case .staleAppArtifact: return "bolt.fill"
        }
    }

    /// A longer help/tooltip string describing exactly what the primary button will do.
    var actionHelp: String {
        switch kind {
        case .resumableDownload: return "Clear the stale cached download, then run the command again"
        case .staleAppArtifact: return "Run the command again with --force to overwrite the existing app"
        }
    }
}

/// Pure detector for recoverable-failure signatures in a command's console output. Kept free of
/// AppKit and BrewModel state so it is trivially unit-testable in the lightweight RunnerTests
/// target. The model calls `detect(in:)` once a command finishes with a non-zero exit.
enum RecoveryHintDetector {
    /// curl error 56 with a resume-specific message. Homebrew surfaces this in two shapes:
    ///   `curl: (56) HTTP server doesn't seem to support byte ranges. Cannot resume.`
    ///   `Error: … Cannot resume` (the wrapping brew "Download failed" line)
    /// We require the curl-56 marker OR the explicit "Cannot resume" / "byte ranges" phrasing so an
    /// unrelated failure isn't offered a cache-clear it can't fix.
    private static let resumeSignatures: [String] = [
        "cannot resume",
        "doesn't seem to support byte ranges",
        "does not seem to support byte ranges",
    ]

    /// `Download failed on Cask 'postman'` / `Download failed on Formula 'wget'` — captures the
    /// package kind and token so the retry can target `brew cleanup <token>`.
    private static let targetRegex = try! NSRegularExpression(
        pattern: #"Download failed on (Cask|Formula)\s+['""]([^'""]+)['""]"#,
        options: [.caseInsensitive])

    /// `Error: whatsapp: It seems there is already an App at '…'` — the leftover-artifact failure
    /// that blocks a cask upgrade. Captures the token from the `Error: <token>:` prefix.
    private static let staleArtifactRegex = try! NSRegularExpression(
        pattern: #"Error:\s+([A-Za-z0-9][A-Za-z0-9@+._/-]*):\s+It seems there is already an App at"#,
        options: [.caseInsensitive])

    /// Inspect a whole command output. Returns a hint when the output shows a recoverable failure,
    /// else nil. Only meaningful for a command that already failed (non-zero exit).
    static func detect(in output: String) -> RecoveryHint? {
        // Stale-app-artifact failure ("It seems there is already an App at …") — recover with --force.
        if let hint = detectStaleArtifact(in: output) { return hint }
        // Resumable-download dead-end (curl-56 / "Cannot resume") — recover by clearing the cache.
        return detectResumableDownload(in: output)
    }

    /// Detect the "already an App at" cask-upgrade failure. Requires the distinctive phrase so an
    /// unrelated error isn't offered a force-retry.
    private static func detectStaleArtifact(in output: String) -> RecoveryHint? {
        guard output.lowercased().contains("it seems there is already an app at") else { return nil }
        var token: String?
        let ns = output as NSString
        if let match = staleArtifactRegex.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { token = name }
        }
        // This failure only happens for casks (they carry the `.app` artifact).
        return RecoveryHint(kind: .staleAppArtifact, token: token, isCask: true)
    }

    /// Detect the resumable-download dead-end (the original v1.19 recovery).
    private static func detectResumableDownload(in output: String) -> RecoveryHint? {
        let lower = output.lowercased()
        // Require a curl-56 line, or an explicit resume/byte-ranges phrase, to avoid false positives.
        let hasCurl56 = lower.contains("curl: (56)")
        let hasResumePhrase = resumeSignatures.contains { lower.contains($0) }
        guard hasCurl56 || hasResumePhrase else { return nil }
        // If curl-56 alone matched, still confirm it's the resume flavour (56 has other causes).
        if hasCurl56 && !hasResumePhrase { return nil }

        // Best-effort: pull the affected token + kind from brew's "Download failed on …" line.
        var token: String?
        var isCask: Bool?
        let ns = output as NSString
        if let match = targetRegex.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: match.range(at: 1)).lowercased()
            let name = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { token = name }
            isCask = kind == "cask"
        }
        return RecoveryHint(kind: .resumableDownload, token: token, isCask: isCask)
    }
}
