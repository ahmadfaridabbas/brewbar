import Foundation

/// Phase 1 in-app update check (detect-and-guide, no self-replace).
///
/// BrewBar is distributed as a ZIP of `BrewBar.app` on GitHub Releases. This model queries the
/// GitHub Releases API for the latest published release, compares its tag to the running app's
/// `CFBundleShortVersionString`, and — when a newer version exists — surfaces it in the Options
/// menu and a header banner. Clicking opens the release page in the browser; downloading/replacing
/// the app in place is a later phase.
///
/// Kept free of AppKit so the version comparison and tag parsing are trivially unit-testable.
enum AppUpdate {
    /// The GitHub owner/repo the releases are published under. Centralized so the URL and the
    /// human-facing release page stay in sync.
    static let repo = "ahmadfaridabbas/brewbar"

    /// The GitHub REST endpoint for the latest (non-draft, non-prerelease) release.
    static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    /// The human-facing latest-release page (opened when the user clicks to update).
    static var latestReleasePage: URL {
        URL(string: "https://github.com/\(repo)/releases/latest")!
    }

    /// Normalize a release tag or version string to comparable numeric components. Accepts tags like
    /// `v1.26`, `1.26`, `v1.26.1`, tolerating a leading `v`/`V` and trailing pre-release suffixes
    /// (e.g. `1.26-beta` → `[1, 26]`). Returns an empty array for anything without a leading number.
    static func versionComponents(_ raw: String) -> [Int] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        // Cut at the first character that isn't a digit or dot (drops `-beta`, `+build`, etc.).
        if let cut = s.firstIndex(where: { !($0.isNumber || $0 == ".") }) {
            s = String(s[..<cut])
        }
        return s.split(separator: ".").compactMap { Int($0) }
    }

    /// True when `candidate` is a strictly newer version than `current` (component-wise numeric
    /// compare, shorter versions zero-padded: `1.26` > `1.25`, `1.26.1` > `1.26`, `1.26` == `1.26`).
    /// Returns false if either string has no parseable leading version (fail safe: never nag).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = versionComponents(candidate)
        let b = versionComponents(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }

    /// Extract the release tag (`tag_name`) from the GitHub `releases/latest` JSON payload.
    /// Returns nil if the payload is missing/misshaped, so a bad response never surfaces a bogus
    /// "update available".
    static func tagName(fromLatestReleaseJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              !tag.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return tag
    }

    /// A display version (no leading `v`) for a tag, e.g. `v1.26` → `1.26`.
    static func displayVersion(fromTag tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        return s
    }
}
