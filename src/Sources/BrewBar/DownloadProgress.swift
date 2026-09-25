import Foundation

/// Live state for the console's download progress bar. Homebrew (under a PTY) prints a curl-style
/// bar like `####################  45.1%` that rewrites one line via carriage returns, preceded by
/// `==> Downloading <url>`. That bar carries only a percentage — no byte totals — so BrewBar looks
/// up the file's size once (a HEAD request on the URL) and derives the downloaded amount from the
/// percentage. The bar stays on screen until the download reaches 100%, the file is written, or the
/// command moves on to a non-download step.
struct DownloadProgress: Equatable {
    /// A human-friendly file name pulled from the download URL (e.g. `ChatGPT-darwin.zip`).
    var fileName: String
    /// Fraction complete in 0...1, taken from brew's `NN.N%` bar.
    var fraction: Double
    /// Total size in bytes when known (resolved asynchronously from the URL). Nil until it arrives.
    var totalBytes: Int64?

    /// Bytes downloaded so far, derived from `fraction` × `totalBytes` when the size is known.
    var downloadedBytes: Int64? {
        guard let total = totalBytes else { return nil }
        return Int64((Double(total) * fraction).rounded())
    }

    /// A short label such as `45%`, `12.3 MB of 27.4 MB · 45%`, or just the fraction when the size
    /// is still unknown.
    var summary: String {
        let percent = "\(Int((fraction * 100).rounded()))%"
        guard let total = totalBytes, let done = downloadedBytes, total > 0 else { return percent }
        return "\(DownloadProgress.format(done)) of \(DownloadProgress.format(total)) · \(percent)"
    }

    /// Byte-count formatter (kept binary-free of AppKit for testability).
    static func format(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        // No decimals for raw bytes; one decimal for larger units.
        if index == 0 { return "\(bytes) \(units[index])" }
        return String(format: "%.1f %@", value, units[index])
    }
}

/// Pure parser that turns a single console line into a progress update. Kept free of AppKit and of
/// BrewModel state so it is trivially unit-testable. The model calls `parse(line:)` for every line
/// it appends and applies the returned action.
enum DownloadProgressParser {
    enum Action: Equatable {
        /// A new download started for `url`; the model should begin (or replace) a progress bar.
        case start(url: String, fileName: String)
        /// The active download advanced to `fraction` (0...1).
        case progress(fraction: Double)
        /// The active download finished (file written) or the command moved to a non-download step;
        /// the model should hide the bar.
        case finish
        /// The line is unrelated to download progress; leave any existing bar untouched.
        case none
    }

    /// A run of bar glyphs (`#`, `=`, `O`, `-`, `.`, `>`, spaces) ending in `NN.N%` or `NN%`.
    private static let barRegex = try! NSRegularExpression(
        pattern: #"^[#=O.\->\s]*?(\d{1,3}(?:\.\d+)?)%\s*$"#)

    static func parse(line rawLine: String) -> Action {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .none }

        // `==> Downloading <url>` starts a fetch. Ignore `==> Downloading from <mirror>` (a redirect
        // notice for the same file) and brew's API-cache preamble (`Downloading Homebrew API data`).
        if let range = line.range(of: #"^==>\s+Downloading\s+"#, options: .regularExpression) {
            let rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("from ") { return .none }
            if rest == "Homebrew API data" || rest.hasPrefix("Homebrew API") { return .none }
            guard rest.lowercased().hasPrefix("http") else { return .none }
            return .start(url: rest, fileName: fileName(fromURL: rest))
        }

        // A finished/settled download: brew writes the cache path or reports it was already there.
        if line.hasPrefix("Downloaded to:") || line.contains("already downloaded")
            || line.hasPrefix("Already downloaded:") {
            return .finish
        }

        // The percentage bar. `100%`/`100.0%` also ends the bar.
        let ns = line as NSString
        if let match = barRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
           let value = Double(ns.substring(with: match.range(at: 1))) {
            let fraction = min(max(value / 100.0, 0), 1)
            return fraction >= 1.0 ? .finish : .progress(fraction: fraction)
        }

        // Any other `==> …` step (Installing, Pouring, Fetching next item, Running, etc.) means the
        // current download is done — hide the bar so it doesn't linger into the install phase.
        if line.hasPrefix("==>") { return .finish }

        return .none
    }

    /// Derive a readable file name from a download URL, stripping query strings and percent-escapes.
    /// Falls back to the host when the path has no usable last component.
    static func fileName(fromURL url: String) -> String {
        // Drop query and fragment.
        var path = url
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        // Trim scheme + host to isolate the path.
        var lastComponent = path
        if let comps = URLComponents(string: url) {
            let trimmed = comps.path.split(separator: "/").last.map(String.init)
            if let trimmed, !trimmed.isEmpty { lastComponent = trimmed }
            else if let host = comps.host { lastComponent = host }
        } else {
            lastComponent = path.split(separator: "/").last.map(String.init) ?? path
        }
        let decoded = lastComponent.removingPercentEncoding ?? lastComponent
        let cleaned = decoded.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? url : cleaned
    }
}
