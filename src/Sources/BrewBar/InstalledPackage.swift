import Foundation

struct InstalledPackage: Identifiable, Equatable {
    let token: String
    let name: String
    let detail: String
    let version: String
    let kind: String
    var id: String { kind + ":" + token }
    var canUninstall: Bool {
        token.range(of: "^[A-Za-z0-9][A-Za-z0-9@+._/-]*$", options: .regularExpression) != nil
    }
    var uninstallArguments: [String] { ["uninstall", kind == "App" ? "--cask" : "--formula", token] }

    static func parse(_ data: Data) throws -> [InstalledPackage] {
        guard let root = try JSONSerialization.jsonObject(with: JSONExtraction.object(from: data)) as? [String: Any],
              let formulae = root["formulae"] as? [[String: Any]],
              let casks = root["casks"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
        var result: [InstalledPackage] = []
        for item in formulae {
            guard let name = item["name"] as? String,
                  let installed = item["installed"] as? [[String: Any]], !installed.isEmpty else { continue }
            result.append(.init(token: item["full_name"] as? String ?? name, name: name,
                                detail: item["desc"] as? String ?? "Command-line tool or library",
                                version: installed.compactMap { $0["version"] as? String }.joined(separator: ", "), kind: "Formula"))
        }
        for item in casks {
            guard let token = item["token"] as? String else { continue }
            let versions: [String]
            if let version = item["installed"] as? String { versions = [version] }
            else { versions = item["installed"] as? [String] ?? [] }
            guard !versions.isEmpty else { continue }
            result.append(.init(token: item["full_token"] as? String ?? token,
                                name: (item["name"] as? [String])?.first ?? token,
                                detail: item["desc"] as? String ?? "Homebrew application",
                                version: versions.joined(separator: ", "), kind: "App"))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
