import Darwin
import Foundation

public struct SSHHostEntry: Sendable, Hashable, Codable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
}

/// Reads concrete Host aliases from ~/.ssh/config (and simple Includes) for the
/// "import from ssh config" picker. ssh itself still resolves the alias at connect time.
public enum SSHConfigParser {
    public static func parse(_ contents: String, baseDir: String = "~/.ssh", depth: Int = 0) -> [SSHHostEntry] {
        var entries: [SSHHostEntry] = []
        var current: [Int] = [] // indices into entries for the active Host block
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                current = []
                for alias in value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                    entries.append(SSHHostEntry(alias: alias))
                    current.append(entries.count - 1)
                }
            case "match":
                current = []
            case "hostname":
                for i in current where entries[i].hostName == nil { entries[i].hostName = value }
            case "user":
                for i in current where entries[i].user == nil { entries[i].user = value }
            case "port":
                for i in current where entries[i].port == nil { entries[i].port = Int(value) }
            case "include" where depth < 4:
                for path in expandInclude(value, baseDir: baseDir) {
                    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                        entries += parse(text, baseDir: baseDir, depth: depth + 1)
                    }
                }
            default:
                break
            }
        }
        var seen = Set<String>()
        return entries.filter { seen.insert($0.alias).inserted }
    }

    public static func load(path: String = "~/.ssh/config") -> [SSHHostEntry] {
        let full = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { return [] }
        return parse(text, baseDir: (full as NSString).deletingLastPathComponent)
    }

    private static func expandInclude(_ value: String, baseDir: String) -> [String] {
        value.split(separator: " ").flatMap { token -> [String] in
            var p = (String(token) as NSString).expandingTildeInPath
            if !p.hasPrefix("/") { p = ((baseDir as NSString).expandingTildeInPath as NSString).appendingPathComponent(p) }
            guard p.contains("*") || p.contains("?") else { return [p] }
            var g = glob_t()
            defer { globfree(&g) }
            guard glob(p, 0, nil, &g) == 0 else { return [] }
            return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
        }
    }
}
