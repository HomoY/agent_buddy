import Foundation

/// A loosely typed view over `JSONSerialization` output, read like
/// `value["message"]["content"].string`. Missing keys read as null, so the
/// agents' evolving log formats never crash a parser.
public struct JSON {
    public let raw: Any?

    public init(_ raw: Any?) {
        self.raw = raw
    }

    public static func parse(_ data: Data) -> JSON? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSON(object)
    }

    public static func parse(_ text: String) -> JSON? {
        parse(Data(text.utf8))
    }

    public subscript(key: String) -> JSON {
        // JSONSerialization's dictionaries are looked in as they are: made a Swift
        // dictionary first, one goes through all its keys at each look.
        if let raw, type(of: raw) is AnyClass {
            return JSON((raw as? NSDictionary)?[key])
        }
        return JSON((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    public var isNull: Bool {
        raw == nil || raw is NSNull
    }

    public var isObject: Bool {
        if let raw, type(of: raw) is AnyClass {
            return raw is NSDictionary
        }
        return raw is [String: Any]
    }

    public var string: String? {
        raw as? String
    }

    /// The string with surrounding whitespace removed, or nil when that leaves nothing.
    public var nonEmptyString: String? {
        guard let text = string, let first = text.unicodeScalars.first, let last = text.unicodeScalars.last else { return nil }
        // Most have nothing to trim: kept as they are.
        if !Self.blank.contains(first), !Self.blank.contains(last) {
            return text
        }
        let trimmed = text.trimmingCharacters(in: Self.blank)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let blank = CharacterSet.whitespacesAndNewlines

    public var bool: Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A finite number, also read from a numeric string.
    public var double: Double? {
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        if let text = raw as? String, let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite {
            return value
        }
        return nil
    }

    public var int: Int? {
        double.map { Int($0) }
    }

    public var array: [JSON] {
        (raw as? [Any])?.map { JSON($0) } ?? []
    }

    public var object: [String: JSON]? {
        (raw as? [String: Any])?.mapValues { JSON($0) }
    }
}
