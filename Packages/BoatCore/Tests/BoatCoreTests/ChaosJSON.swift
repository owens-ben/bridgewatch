import Foundation

/// A JSON tree the chaos tests can break on purpose: numbers and anything else are raw tokens, so a "number" can be
/// `1e309` or `-0`, and objects keep their order and duplicate keys.
indirect enum ChaosJSON {
    case raw(String)
    case string(String)
    case array([ChaosJSON])
    case object([(key: String, value: ChaosJSON)])

    func render() -> String {
        switch self {
        case .raw(let token): return token
        case .string(let text): return Self.quote(text)
        case .array(let items): return "[" + items.map { $0.render() }.joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { Self.quote($0.key) + ":" + $0.value.render() }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// The tree of valid JSON `data` (object keys sorted, so a seed replays), or nil.
    static func parse(_ data: Data) -> ChaosJSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return convert(any)
    }

    private static func convert(_ any: Any) -> ChaosJSON {
        switch any {
        case let dict as [String: Any]:
            return .object(dict.keys.sorted().map { ($0, convert(dict[$0]!)) })
        case let list as [Any]:
            return .array(list.map(convert))
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .raw(number.boolValue ? "true" : "false") }
            return .raw(number.stringValue)
        default:
            return .raw("null")
        }
    }

    /// Every node's path: indices into arrays and objects.
    func paths(prefix: [Int] = []) -> [[Int]] {
        var all = [prefix]
        switch self {
        case .array(let items):
            for (i, item) in items.enumerated() { all += item.paths(prefix: prefix + [i]) }
        case .object(let pairs):
            for (i, pair) in pairs.enumerated() { all += pair.value.paths(prefix: prefix + [i]) }
        default: break
        }
        return all
    }

    func node(at path: [Int]) -> ChaosJSON? {
        guard let first = path.first else { return self }
        let rest = Array(path.dropFirst())
        switch self {
        case .array(let items): return first < items.count ? items[first].node(at: rest) : nil
        case .object(let pairs): return first < pairs.count ? pairs[first].value.node(at: rest) : nil
        default: return nil
        }
    }

    /// This tree with the node at `path` run through `change`; the change gets the node's key when it has one, and
    /// may return nil to delete the node (from its array or object).
    func replacing(at path: [Int], _ change: (ChaosJSON, String?) -> ChaosJSON?) -> ChaosJSON {
        guard let first = path.first else { return change(self, nil) ?? self }
        let rest = Array(path.dropFirst())
        switch self {
        case .array(var items) where first < items.count:
            if rest.isEmpty {
                if let new = change(items[first], nil) { items[first] = new } else { items.remove(at: first) }
            } else {
                items[first] = items[first].replacing(at: rest, change)
            }
            return .array(items)
        case .object(var pairs) where first < pairs.count:
            if rest.isEmpty {
                if let new = change(pairs[first].value, pairs[first].key) { pairs[first].value = new } else { pairs.remove(at: first) }
            } else {
                pairs[first].value = pairs[first].value.replacing(at: rest, change)
            }
            return .object(pairs)
        default:
            return self
        }
    }
}
