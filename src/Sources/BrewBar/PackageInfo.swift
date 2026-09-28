import Foundation

/// Rich detail for a single package, parsed from `brew info --json=v2 <token>`. Backs the per-row
/// info popover: description, homepage, version, dependencies, install size, and any caveats.
/// Kept pure and AppKit-free so it compiles in the lightweight RunnerTests target.
struct PackageInfo: Equatable {
    let token: String
    let name: String
    let kind: String          // "Formula" or "App"
    let description: String
    let homepage: String
    let version: String
    let dependencies: [String]
    /// Human-readable install size (formulae only; casks don't report a size). Nil when unknown.
    let installSize: String?
    /// Caveats text brew prints after install (e.g. "add this to your PATH"). Nil when none.
    let caveats: String?

    /// Whether the homepage looks like a safe http(s) URL we can open in the browser.
    var homepageIsValid: Bool {
        guard let url = URL(string: homepage), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    /// Parse `brew info --json=v2 <token>` for the FIRST package in the payload. brew returns the
    /// same v2 envelope as search (`{ "formulae": [...], "casks": [...] }`); a single-token info call
    /// yields exactly one entry in one of the two arrays. Tolerates a non-JSON preamble via
    /// `JSONExtraction`. Returns nil when neither array has a usable entry.
    static func parse(_ data: Data) -> PackageInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: JSONExtraction.object(from: data)) as? [String: Any]
        else { return nil }
        if let formulae = root["formulae"] as? [[String: Any]], let item = formulae.first,
           let name = item["name"] as? String {
            let stable = (item["versions"] as? [String: Any])?["stable"] as? String ?? "—"
            // Dependencies: brew lists runtime deps under "dependencies".
            let deps = (item["dependencies"] as? [String]) ?? []
            // Install size: prefer the installed size, else the bottle/estimated size when present.
            let size = formulaInstallSize(item)
            let caveats = (item["caveats"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PackageInfo(
                token: item["full_name"] as? String ?? name,
                name: name,
                kind: "Formula",
                description: item["desc"] as? String ?? "Command-line tool or library",
                homepage: item["homepage"] as? String ?? "",
                version: stable,
                dependencies: deps,
                installSize: size,
                caveats: (caveats?.isEmpty == false) ? caveats : nil)
        }
        if let casks = root["casks"] as? [[String: Any]], let item = casks.first,
           let token = item["token"] as? String {
            let caveats = (item["caveats"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // A cask's dependencies live under depends_on.cask / depends_on.formula.
            var deps: [String] = []
            if let dependsOn = item["depends_on"] as? [String: Any] {
                deps += (dependsOn["formula"] as? [String]) ?? []
                deps += (dependsOn["cask"] as? [String]) ?? []
            }
            return PackageInfo(
                token: item["full_token"] as? String ?? token,
                name: (item["name"] as? [String])?.first ?? token,
                kind: "App",
                description: item["desc"] as? String ?? "Homebrew application",
                homepage: item["homepage"] as? String ?? "",
                version: item["version"] as? String ?? "—",
                dependencies: deps,
                installSize: nil,  // casks don't report an install size in --json=v2
                caveats: (caveats?.isEmpty == false) ? caveats : nil)
        }
        return nil
    }

    /// Best-effort human-readable install size for a formula. brew reports byte counts under an
    /// installed entry's `installed_on_request`/`size` in some versions, or a bottle size. We look
    /// for a numeric byte count and format it; return nil when nothing usable is present.
    private static func formulaInstallSize(_ item: [String: Any]) -> String? {
        // Newer brew: installed[].installed_size (bytes). Older: no size field.
        if let installed = item["installed"] as? [[String: Any]],
           let bytes = installed.compactMap({ $0["installed_size"] as? NSNumber }).first {
            return formatBytes(bytes.int64Value)
        }
        return nil
    }

    /// Binary-unit byte formatter (matches the DownloadProgress convention: MB == MiB).
    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[unit])
    }
}
