import Foundation

/// A package discovered via `brew search` and enriched via `brew info --json=v2`. Carries enough
/// to render a rich row (name, description, version, kind) and to know whether it is already
/// installed, so the UI can offer Install or mark it as present.
struct SearchResult: Identifiable, Equatable {
    let token: String
    let name: String
    let detail: String
    let version: String
    let kind: String        // "Formula" or "App"
    let installed: Bool
    var id: String { kind + ":" + token }

    /// Same validation as uninstall: a conservative token charset so nothing shell-like reaches brew.
    var valid: Bool {
        token.range(of: "^[A-Za-z0-9][A-Za-z0-9@+._/-]*$", options: .regularExpression) != nil
    }
    var installArguments: [String] { ["install", kind == "App" ? "--cask" : "--formula", token] }

    /// Parse `brew info --json=v2 <tokens…>` into results. Tolerates a non-JSON preamble (e.g.
    /// brew's `==> Downloading Homebrew API data`) via `JSONExtraction`.
    static func parse(_ data: Data) throws -> [SearchResult] {
        guard let root = try JSONSerialization.jsonObject(with: JSONExtraction.object(from: data)) as? [String: Any],
              let formulae = root["formulae"] as? [[String: Any]],
              let casks = root["casks"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
        var result: [SearchResult] = []
        for item in formulae {
            guard let name = item["name"] as? String else { continue }
            let stable = (item["versions"] as? [String: Any])?["stable"] as? String ?? "—"
            let installedList = item["installed"] as? [[String: Any]] ?? []
            result.append(.init(token: item["full_name"] as? String ?? name, name: name,
                                detail: item["desc"] as? String ?? "Command-line tool or library",
                                version: stable, kind: "Formula", installed: !installedList.isEmpty))
        }
        for item in casks {
            guard let token = item["token"] as? String else { continue }
            // A cask's `installed` is a version string when present, null otherwise.
            let installedVersion = item["installed"] as? String
            result.append(.init(token: item["full_token"] as? String ?? token,
                                name: (item["name"] as? [String])?.first ?? token,
                                detail: item["desc"] as? String ?? "Homebrew application",
                                version: item["version"] as? String ?? "—",
                                kind: "App", installed: installedVersion != nil))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Parse the plain-text `brew search <query>` output into candidate tokens. When output is not
    /// a TTY, brew prints one name per line with no section headers; we still skip any `==>` lines,
    /// blank lines, and obvious warnings so only real tokens remain.
    static func searchTokens(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("==>") && !line.hasPrefix("Warning:") && !line.hasPrefix("Error:")
                    && line.range(of: "^[A-Za-z0-9][A-Za-z0-9@+._/-]*$", options: .regularExpression) != nil
            }
    }
}
