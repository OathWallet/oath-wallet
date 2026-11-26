import Foundation

/// Structured, transient form input. This never derives keys or changes saved accounts.
/// Invalid/unfinished input stays invalid rather than silently selecting another path.
public struct HDAccountPathDraft: Identifiable, Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        public fileprivate(set) var digits: String
        public fileprivate(set) var hardened: Bool
        public var value: UInt32? {
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt32(digits), value <= HDAccountPathDraft.maximumIndex else { return nil }
            return value
        }
        public var text: String { (digits.isEmpty ? "…" : digits) + (hardened ? "'" : "") }
    }

    public static let rootComponent = "m"
    public static let maximumIndex: UInt32 = 0x7fff_ffff
    public static let maximumComponents = 10
    public static let maximumPaths = 20
    public let id = UUID()
    public let family: HDAccountFamily
    public private(set) var components: [Component]

    public init(family: HDAccountFamily, path: String) throws {
        self.family = family
        components = try family.canonicalPath(path).split(separator: "/").dropFirst().map {
            let hardened = $0.last == "'"
            return Component(digits: String(hardened ? $0.dropLast() : $0), hardened: hardened)
        }
    }

    public init(family: HDAccountFamily, excluding saved: Set<String>) {
        self.family = family
        // Automatic numbering is bounded; custom editing remains available at that limit.
        // Expected form validation, not a diagnostics-worthy service failure.
        let path = (try? family.nextDefaultPath(existing: saved))
            ?? (family == .evm ? "m/44'/60'/0'/0/0" : "m/44'/501'/0'/0'")
        components = path.split(separator: "/").dropFirst().map {
            let hardened = $0.last == "'"
            return Component(digits: String(hardened ? $0.dropLast() : $0), hardened: hardened)
        }
    }

    public var canonicalPath: String? {
        guard components.allSatisfy({ $0.value != nil }) else { return nil }
        // Expected live form validation; never log user-entered paths.
        return try? family.canonicalPath(Self.rootComponent + "/" + components.map { $0.digits + ($0.hardened ? "'" : "") }.joined(separator: "/"))
    }

    public mutating func setDigits(_ input: String, at index: Int) {
        guard components.indices.contains(index) else { return }
        // Number pads can use localized decimal digits. Preserve invalid characters
        // (including pasted separators/signs) so validation cannot change their meaning.
        components[index].digits = input.map { character in
            if character.unicodeScalars.count == 1,
               character.unicodeScalars.first?.properties.numericType == .decimal,
               let number = character.wholeNumberValue { return String(number) }
            return String(character)
        }.joined()
    }

    public mutating func increment(at index: Int) {
        guard components.indices.contains(index), let value = components[index].value,
              value < Self.maximumIndex else { return }
        components[index].digits = String(value + 1)
    }

    public mutating func decrement(at index: Int) {
        guard components.indices.contains(index), let value = components[index].value, value > 0 else { return }
        components[index].digits = String(value - 1)
    }

    public mutating func setHardened(_ hardened: Bool, at index: Int) {
        guard components.indices.contains(index), family != .solana || hardened else { return }
        components[index].hardened = hardened
    }

    public mutating func appendComponent() {
        guard components.count < Self.maximumComponents else { return }
        components.append(Component(digits: "0", hardened: family == .solana))
    }

    public mutating func removeLastComponent() {
        guard components.count > 1 else { return }
        components.removeLast()
    }

    public static func paths(_ drafts: [Self], family: HDAccountFamily) throws -> [String] {
        guard !drafts.isEmpty, drafts.count <= maximumPaths else { throw HDAccountDerivation.ValidationError.tooManyPaths }
        let paths = try drafts.map { draft in
            guard draft.family == family, let path = draft.canonicalPath else { throw HDAccountDerivation.ValidationError.invalidPath }
            return path
        }
        // Keep the same canonicalization, uniqueness and family rules as the vault import.
        return try family.paths(in: paths.joined(separator: "\n"))
    }
}
