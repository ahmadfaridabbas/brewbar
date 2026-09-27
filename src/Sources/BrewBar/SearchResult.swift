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

    /// The single term to hand to `brew search`. Homebrew matches a query against package **tokens**
    /// (and descriptions), and tokens never contain spaces or capitals — so a human, multi-word query
    /// like "Tinycast Beta" can never substring-match a real token (brew falls back to a fuzzy match
    /// and returns unrelated packages). To stay reliable we search on the single most **distinctive**
    /// word — the longest alphanumeric word — then filter the enriched results client-side against the
    /// full query (see `matches(query:)`). A single-word query passes through unchanged.
    ///
    /// Words are split on whitespace; the longest word wins (ties → the earliest), lowercased. Any
    /// non-token characters within a word (e.g. stray punctuation) are dropped so only a brew-safe
    /// term is produced. Returns `nil` if nothing usable remains.
    static func distinctiveTerm(_ query: String) -> String? {
        let words = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { word -> String in
                String(word.lowercased().unicodeScalars.filter {
                    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789@+._/-").contains($0)
                })
            }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        // Longest word is the most distinctive; ties resolve to the first occurrence.
        return words.reduce(words[0]) { best, next in next.count > best.count ? next : best }
    }

    /// Client-side multi-word filter: keep a result only when **every** word of the user's original
    /// query appears (case-insensitively, as a substring) in either the package `token` or its display
    /// `name`. This is what makes "Tinycast Beta" resolve to the `tinycast@beta` / "Tinycast Beta"
    /// package after brew is searched on just "tinycast". A single-word query keeps every result whose
    /// token or name contains that word — matching brew's own substring behaviour, so no regression.
    func matches(query: String) -> Bool {
        let haystack = (token + " " + name).lowercased()
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        guard !words.isEmpty else { return true }
        return words.allSatisfy { haystack.contains($0) }
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
