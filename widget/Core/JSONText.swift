import Foundation

/// Ordered JSON that serializes byte for byte like JavaScript's JSON.stringify
/// (JSONEncoder reorders keys, escapes "/" and writes `"key" : value`).
enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    func compact() -> String { serialize(indent: nil, level: 0) }

    func pretty() -> String { serialize(indent: "  ", level: 0) }

    private func serialize(indent: String?, level: Int) -> String {
        switch self {
        case .string(let value): return Self.quote(value)
        case .number(let value): return Self.format(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            return Self.container("[", "]", items.map { $0.serialize(indent: indent, level: level + 1) }, indent: indent, level: level)
        case .object(let fields):
            let separator = indent == nil ? ":" : ": "
            let members = fields.map { Self.quote($0.0) + separator + $0.1.serialize(indent: indent, level: level + 1) }
            return Self.container("{", "}", members, indent: indent, level: level)
        }
    }

    private static func container(_ open: String, _ close: String, _ members: [String], indent: String?, level: Int) -> String {
        guard !members.isEmpty else { return open + close }
        guard let indent else { return open + members.joined(separator: ",") + close }
        let inner = "\n" + String(repeating: indent, count: level + 1)
        return open + inner + members.joined(separator: "," + inner) + "\n" + String(repeating: indent, count: level) + close
    }

    private static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{8}": result += "\\b"
            case "\u{C}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{0}"..."\u{1F}": result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    // Beyond 2^53 an integral Double prints as its shortest round-trip digits followed by zeros, not its exact value.
    private static func format(_ value: Double) -> String {
        guard value == value.rounded(), abs(value) < 1e21 else { return value.description }
        if abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        let sign = value < 0 ? "-" : ""
        let parts = abs(value).description.split(separator: "e")
        let mantissa = parts[0].split(separator: ".")
        guard parts.count > 1 else { return sign + mantissa[0] }
        let digits = mantissa.joined()
        return sign + digits + String(repeating: "0", count: max(0, Int(parts[1])! + 1 - digits.count))
    }
}
