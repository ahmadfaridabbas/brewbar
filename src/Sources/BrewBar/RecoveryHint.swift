import Foundation

/// A recoverable failure that BrewBar can offer to fix with one click. Currently this covers
/// Homebrew's "resumable download" dead-end: when a partial file is left in brew's download cache
/// and the file's HTTP server does not honour byte-range (resume) requests, curl aborts with
/// `curl: (56) … Cannot resume`. brew retries once, hits the same wall, and gives up. The fix is to
/// clear the stale cached download so the next fetch starts fresh — exactly what this hint drives.
struct RecoveryHint: Equatable {
    /// The affected package token (e.g. `postman`), pulled from brew's
    /// `Download failed on Cask 'postman'` / `Formula 'wget'` line when present.
    var token: String?
    /// Whether the affected package is a cask (vs. a formula). Nil when brew didn't say.
    var isCask: Bool?
    /// A short, user-facing explanation shown in the recovery bar.
    var message: String {
        let name = token.map { "“\($0)”" } ?? "this package"
        return "The download server for \(name) doesn't support resuming a partial file. "
            + "Clear the cached download and try again."
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

    /// Inspect a whole command output. Returns a hint when the output shows a resumable-download
    /// failure, else nil. Only meaningful for a command that already failed (non-zero exit).
    static func detect(in output: String) -> RecoveryHint? {
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
        return RecoveryHint(token: token, isCask: isCask)
    }
}
