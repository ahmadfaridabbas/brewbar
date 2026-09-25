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
    /// Received bytes when brew reports them directly (parallel-queue `Downloading X/Y`). When set,
    /// this is authoritative and the fraction/total are derived from brew's own numbers rather than
    /// a HEAD estimate.
    var exactReceivedBytes: Int64?

    /// Bytes downloaded so far: brew's exact figure when available, else `fraction` × `totalBytes`.
    var downloadedBytes: Int64? {
        if let exact = exactReceivedBytes { return exact }
        guard let total = totalBytes else { return nil }
        return Int64((Double(total) * fraction).rounded())
    }

    /// Apply brew's exact received/total byte counter. Also updates `fraction` so the bar fills to
    /// brew's real position, and marks the size as authoritative (no HEAD estimate needed).
    mutating func applyExactBytes(received: Int64, total: Int64) {
        guard total > 0 else { return }
        exactReceivedBytes = received
        totalBytes = total
        fraction = min(max(Double(received) / Double(total), 0), 1)
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
        /// The active download advanced to a known byte position (brew's own counter, e.g.
        /// `Downloading 263.1MB/373.1MB`). Carries exact received/total bytes so the bar shows
        /// brew's real numbers without a HEAD request. `name` is the cask/file when the status line
        /// includes it (`Cask readdle-spark (…) … Downloading …`), else nil.
        case bytes(received: Int64, total: Int64, name: String?)
        /// The active download finished (file written) or the command moved to a non-download step;
        /// the model should hide the bar.
        case finish
        /// The line is unrelated to download progress; leave any existing bar untouched.
        case none
    }

    /// A run of bar glyphs (`#`, `=`, `O`, `-`, `.`, `>`, spaces) ending in `NN.N%` or `NN%`.
    private static let barRegex = try! NSRegularExpression(
        pattern: #"^[#=O.\->\s]*?(\d{1,3}(?:\.\d+)?)%\s*$"#)

    /// brew's parallel-download-queue byte counter, e.g. `Downloading 263.1MB/373.1MB` or
    /// `Downloaded 373.1MB/373.1MB` (optionally embedded in a `Cask name (ver) ####  Downloading …`
    /// status line). Captures received value+unit and total value+unit.
    private static let byteRegex = try! NSRegularExpression(
        pattern: #"Download(?:ing|ed)\s+([\d.]+)\s*([KMGT]?B)\s*/\s*([\d.]+)\s*([KMGT]?B)"#,
        options: [.caseInsensitive])

    /// `Cask <name> (<ver>)` / `Formula <name> (<ver>)` prefix on brew's parallel-queue status line.
    private static let caskNameRegex = try! NSRegularExpression(
        pattern: #"(?:Cask|Formula)\s+([A-Za-z0-9@._+-]+)"#)

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

        // brew's parallel-queue byte counter (`Downloading 263.1MB/373.1MB` /
        // `Downloaded 373.1MB/373.1MB`), possibly inside a `Cask name (ver) #### Downloading …` line.
        // This carries brew's exact numbers, so prefer it over the percentage bar. When received
        // meets/exceeds total the download is complete.
        let ns = line as NSString
        if let match = byteRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
           let received = bytes(value: ns.substring(with: match.range(at: 1)),
                                unit: ns.substring(with: match.range(at: 2))),
           let total = bytes(value: ns.substring(with: match.range(at: 3)),
                             unit: ns.substring(with: match.range(at: 4))),
           total > 0 {
            // Pull the cask/formula name from a `Cask <name> (<ver>)` or `Formula <name>` prefix.
            var name: String?
            if let m = caskNameRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let n = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { name = n }
            }
            return received >= total ? .finish : .bytes(received: received, total: total, name: name)
        }

        // The percentage bar. `100%`/`100.0%` also ends the bar.
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

    /// Convert a brew byte figure (e.g. value "263.1", unit "MB") to a byte count. brew uses binary
    /// units (MB == MiB). Returns nil for an unparseable value.
    static func bytes(value: String, unit: String) -> Int64? {
        guard let n = Double(value) else { return nil }
        let factor: Double
        switch unit.uppercased() {
        case "B": factor = 1
        case "KB": factor = 1024
        case "MB": factor = 1024 * 1024
        case "GB": factor = 1024 * 1024 * 1024
        case "TB": factor = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64((n * factor).rounded())
    }
}
