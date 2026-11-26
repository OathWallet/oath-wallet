import Foundation
import OathAezeed
import OathBitcoin

@main struct CheckMnemonicImport {
    struct Vector: Decodable { let entropy: String; let mnemonic: String }

    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
            // Reasons are fixed strings and never print recovery material.
            precondition(condition(), reason)
            checks += 1
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : root.appendingPathComponent("OathApp/Resources/BIP39")
        let validator = try OathMnemonicValidator.load {
            resources.appendingPathComponent($0 + "." + $1)
        }
        func formatted(_ words: [String]) -> [String] {
            let numbered = words.enumerated()
            return [
                numbered.map { "\($0.offset + 1).\n\($0.element)" }.joined(separator: "\n\n"),
                numbered.map { "\($0.offset + 1).\($0.element)" }.joined(separator: " "),
                numbered.map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: "\r\n"),
                numbered.map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: ", "),
                numbered.map { "\($0.offset + 1):\($0.element)" }.joined(separator: "\n"),
                numbered.map { "\($0.offset + 1)\n\($0.element)" }.joined(separator: "\n"),
                words.map { "• \($0)" }.joined(separator: "\n"),
                words.map { "\"\($0)\"" }.joined(separator: ","),
                words.joined(separator: " / | ; + — \t"),
                numbered.map { "\(($0.offset + 1).description.applyingTransform(.fullwidthToHalfwidth, reverse: true)!).\($0.element.uppercased())" }.joined(separator: "\u{3000}")
            ]
        }
        var vectorCount = 0
        var coveredCounts = Set<Int>()
        for file in ["BIP39Vectors", "BIP39AdditionalVectors"] {
            let data = try Data(contentsOf: root.appendingPathComponent("Tools/Fixtures/\(file).json"))
            let vectors = try JSONDecoder().decode([String: [Vector]].self, from: data)
            check(Set(vectors.keys) == Set(OathMnemonicValidator.languages), "Every official word list has independent fixtures")
            for cases in vectors.values {
                for vector in cases {
                    vectorCount += 1
                    let words = OathMnemonicValidator.words(in: vector.mnemonic)
                    coveredCounts.insert(words.count)
                    check(validator.validate(vector.mnemonic).isValid, "Independent reference phrase must validate")
                    check(validator.validate(vector.mnemonic.precomposedStringWithCanonicalMapping).isValid, "NFC input must normalize to BIP-39 NFKD")
                    check(validator.validate(vector.mnemonic.uppercased()).isValid, "Case normalization is language-independent")
                    let spaced = " \n" + words.joined(separator: "\u{3000}\t\u{00A0}") + "\r\n"
                    check(validator.validate(spaced).isValid, "Unicode separators and pasted newlines normalize")
                    check(validator.verifiedPhrase(spaced)?.phrase == words.joined(separator: " "), "The handoff contains canonical words in their original order")
                    check(words.count * 11 * 32 / 33 == vector.entropy.count * 4, "Reference entropy length and word count agree")
                    for input in formatted(words) {
                        check(OathMnemonicValidator.words(in: input) == words, "Formatting cleanup preserves every reference word and its order")
                        check(validator.verifiedPhrase(input)?.phrase == words.joined(separator: " "), "Formatted reference phrases reach the same verified handoff")
                    }
                    let draft = OathRecoveryPhraseDraft(validator: validator)
                    draft.replace(with: formatted(words)[0])
                    check(draft.wordCount == words.count && draft.submit()?.phrase == words.joined(separator: " "), "The production draft imports numbered multiline reference phrases")
                }
            }
        }
        check(vectorCount == 260, "All pinned and independently generated reference vectors were read")
        check(coveredCounts == OathMnemonicValidator.wordCounts, "All five BIP-39 lengths were exercised")
        let valid = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        let invalidChecksum = Array(repeating: "abandon", count: 12).joined(separator: " ")
        check(validator.validate(invalidChecksum) == .checksum, "Dictionary words alone are not a valid phrase")
        check(validator.validate(valid) == .valid(language: "english"), "Duplicate words are valid when the checksum matches")
        check(validator.validate("\n \t") == .empty, "Whitespace is empty input")
        for count in 1...30 where !OathMnemonicValidator.wordCounts.contains(count) {
            check(validator.validate(Array(repeating: "abandon", count: count).joined(separator: " ")) == .wordCount(count), "Unsupported word counts are rejected")
        }
        check(validator.validate(valid.replacingOccurrences(of: "about", with: "notaword")) == .unknownWord(12), "Unknown words return their position without echoing material")
        check(validator.validate(valid.replacingOccurrences(of: "about", with: "abo")) == .unknownWord(12), "Unambiguous prefixes are still not complete words")
        check(validator.verifiedPhrase(valid + ".")?.phrase == valid, "Trailing punctuation is formatting")
        check(!validator.validate("https://example.com/?phrase=" + valid).isValid, "QR URLs are not treated as phrases")
        check(!validator.validate("{\"phrase\":\"" + valid + "\"}").isValid, "Arbitrary structured QR payloads are rejected")
        check(validator.validate(String(repeating: "x", count: 4_097)) == .tooLong, "Oversized input fails before tokenization")
        check(validator.validate(valid.replacingOccurrences(of: "about", with: "a\u{200B}bout")) == .unknownWord(12), "Invisible characters are not silently stripped")
        check(validator.validate(valid.replacingOccurrences(of: "about", with: "あいこくしん")) == .mixedLanguages, "Words from different lists cannot be mixed")
        for invalidWord in ["aba1ndon", "1abandon", "abandon1", "aban-don", "aban/don"] {
            check(!validator.validate(valid.replacingOccurrences(of: "abandon", with: invalidWord)).isValid,
                  "Cleanup never repairs or joins a damaged recovery word")
        }
        for input in formatted(OathMnemonicValidator.words(in: invalidChecksum)) {
            check(validator.validate(input) == .checksum, "Formatting never bypasses the checksum")
        }
        let numberedUnknown = formatted(OathMnemonicValidator.words(in: valid.replacingOccurrences(of: "about", with: "notaword")))[0]
        check(validator.validate(numberedUnknown) == .unknownWord(12), "Unknown-word positions count recovery words rather than labels")
        check(OathMnemonicValidator.words(in: "① abandon ② ability ٣. able") == ["abandon", "ability", "able"], "Compatibility and non-ASCII list numbers are formatting")
        check(validator.validate("• 1.\n2) [3] , ; +") == .empty, "Formatting without words is empty input")
        check(!validator.validate("{\"abandon\":\"" + valid.dropFirst(8) + "\"}").isValid, "Even dictionary-word JSON keys cannot become recovery words")
        let ordered = "legal winner thank year wave sausage worth useful legal winner thank yellow"
        let descendingLabels = OathMnemonicValidator.words(in: ordered).enumerated().map { "\(12 - $0.offset). \($0.element)" }.joined(separator: "\n")
        check(validator.verifiedPhrase(descendingLabels)?.phrase == ordered, "Labels never reorder the entered recovery words")

        func cursor(_ value: String) -> NSRange { NSRange(location: value.utf16.count, length: 0) }
        check(validator.suggestions(in: "aba", selection: cursor("aba")).first == "abandon", "Prefix completion uses the actual dictionary")
        let scrollable = validator.suggestions(in: "a", selection: cursor("a"))
        check(scrollable.count == 32, "A broad prefix supplies a bounded scrollable set instead of only three words")
        check(scrollable.contains("absurd"), "Later dictionary matches remain available beyond the initial visible words")
        check(Set(scrollable).count == scrollable.count, "Scrollable completions contain no duplicates")
        check(scrollable == scrollable.sorted(), "English matches retain dictionary order")
        check(scrollable.allSatisfy { $0.hasPrefix("a") }, "Every suggestion completes the entered prefix")
        check(validator.suggestions(in: "a", selection: cursor("a"), limit: 2) == Array(scrollable.prefix(2)), "An explicit smaller limit is honored")
        check(validator.suggestions(in: "a", selection: cursor("a"), limit: 0).isEmpty, "A zero limit produces no completions")
        check(validator.suggestions(in: "abo", selection: cursor("abo")) == ["about", "above"], "Narrow results do not pad the row with unrelated words")
        for word in scrollable {
            check(validator.completing(word, in: "a", selection: cursor("a"))?.text == word + " ", "Every scrollable result is a real dictionary word that can be inserted")
        }
        check(validator.suggestions(in: "abandon ", selection: cursor("abandon ")).isEmpty, "No guessed next recovery word is offered")
        check(validator.suggestions(in: "zzzz", selection: cursor("zzzz")).isEmpty, "An unmatched prefix has no suggestions")
        check(validator.suggestions(in: "aba", selection: NSRange(location: NSNotFound, length: 0)).isEmpty, "Invalid selection is safe")
        check(validator.suggestions(in: "aba", selection: NSRange(location: 80, length: 0)).isEmpty, "Out-of-bounds selection is safe")
        let middle = "about aba ability"
        let position = NSRange(location: 9, length: 0)
        let completion = validator.completing("abandon", in: middle, selection: position)
        check(completion?.text == "about abandon ability", "Middle-word replacement preserves surrounding words")
        check(completion?.selection.location == 14, "Caret advances to the next word")
        check(validator.completing("abandon", in: "abanxxxx next", selection: NSRange(location: 4, length: 0))?.text == "abandon next", "Completion replaces the whole current token, including its suffix")
        check(validator.completing("about", in: "aba", selection: cursor("aba")) == nil, "Stale suggestions cannot replace a newly changed prefix")
        check(validator.completing("notaword", in: "not", selection: cursor("not")) == nil, "Completion never inserts unknown words")
        check(validator.suggestions(in: "あい", selection: cursor("あい")).contains("あいこくしん"), "Japanese completion works with native characters")
        check(validator.suggestions(in: "ába", selection: cursor("ába")).contains("ábaco"), "Accent composition normalizes for completion")
        check(validator.suggestions(in: "1.aba", selection: cursor("1.aba")).first == "abandon", "Suggestions understand attached numbered-list labels")
        check(validator.suggestions(in: "• aba", selection: cursor("• aba")).first == "abandon", "Suggestions understand bullets")
        check(validator.completing("abandon", in: "1. aba 2. ability", selection: NSRange(location: 6, length: 0))?.text == "1. abandon 2. ability", "Completion replaces the word while preserving numbered neighbors")

        let draft = OathRecoveryPhraseDraft(validator: validator)
        check(draft.submit() == nil && draft.attemptedImport, "Empty submit cannot navigate")
        draft.replace(with: invalidChecksum)
        check(draft.submit() == nil, "Invalid checksum cannot reach the import handoff")
        draft.replace(with: valid)
        check(draft.submit()?.phrase == valid, "Valid input reaches the typed handoff")
        draft.isComposing = true
        check(draft.submit() == nil, "Uncommitted keyboard composition cannot be imported")
        draft.isComposing = false
        check(!draft.receiveScan("bitcoin:unrelated") && draft.text == valid, "Unrelated QR codes preserve the current draft")
        check(!draft.receiveScan(invalidChecksum) && draft.text == valid, "Invalid QR checksums preserve the current draft")
        check(draft.receiveScan(valid.uppercased()), "Valid QR input uses the same validation path")
        for input in formatted(OathMnemonicValidator.words(in: valid)) {
            check(draft.receiveScan(input) && draft.submit()?.phrase == valid, "Formatted QR input reaches the canonical import handoff")
        }
        let previous = draft.text
        check(!draft.receiveScan(String(repeating: "x", count: 4_097)) && draft.text == previous, "Oversized scans preserve the current draft")
        draft.replace(with: String(repeating: "x", count: 4_097))
        check(draft.inputRejected && draft.submit() == nil, "Rejected oversized paste blocks importing stale text")
        draft.replace(with: "aba")
        draft.complete("abandon")
        check(draft.text == "abandon " && draft.selection.location == 8, "Suggestion tap updates input and caret together")
        draft.replace(with: "a")
        check(draft.suggestions == scrollable, "The input draft exposes the full scrollable result set")
        draft.complete("absurd")
        check(draft.text == "absurd " && draft.selection.location == 7, "Selecting a later match updates the input and caret")
        draft.clear()
        check(draft.text.isEmpty && draft.selection.location == 0 && !draft.attemptedImport && !draft.inputRejected, "Leaving the flow clears draft state")
        let missing = OathRecoveryPhraseDraft(validator: nil)
        missing.replace(with: valid)
        check(missing.validation == .unavailable && missing.submit() == nil, "Missing dictionaries fail closed")
        do {
            _ = try OathMnemonicValidator.load { _, _ in nil }
            check(false, "Missing resources must throw")
        } catch { check(true, "Missing resources are handled") }

        // A reordered, otherwise complete dictionary would validate the wrong
        // entropy. Its pinned content hash must reject it before use.
        let altered = FileManager.default.temporaryDirectory.appendingPathComponent("oath-wordlist-check-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: altered) }
        var wordList = try String(contentsOf: resources.appendingPathComponent("bip39_english.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        wordList.swapAt(0, 1)
        try (wordList.joined(separator: "\n") + "\n").write(to: altered, atomically: true, encoding: .utf8)
        do {
            _ = try OathMnemonicValidator.load { name, ext in
                name == "bip39_english" ? altered : resources.appendingPathComponent(name + "." + ext)
            }
            check(false, "Corrupted dictionary order must be rejected")
        } catch { check(true, "Pinned resource integrity fails closed") }

        // Exercise real format recognition and KDFs with public reference data.
        // Seed extensions remain byte-for-byte separate from formatting cleanup.
        struct SeedVector: Decodable { let phrase: String; let password: String }
        let electrumURL = root.appendingPathComponent("Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/electrum-reference.json")
        var electrumKinds = Set<String>()
        for vector in try JSONDecoder().decode([SeedVector].self, from: Data(contentsOf: electrumURL)) {
            let words = vector.phrase.split(whereSeparator: \.isWhitespace).map(String.init)
            for input in formatted(words) {
                draft.replace(with: input)
                draft.selectFormat(.electrum)
                check(draft.isElectrum && draft.electrumKind == ElectrumMnemonic.kind(vector.phrase), "Formatted Electrum input retains its reference format")
                check(ElectrumMnemonic.normalize(draft.importText) == ElectrumMnemonic.normalize(vector.phrase), "Electrum decoding receives the reference words")
            }
            if let kind = draft.electrumKind, electrumKinds.insert(kind.rawValue).inserted {
                let canonicalMaterial = try ElectrumMnemonic.decode(vector.phrase, passphrase: vector.password)
                let formattedMaterial = try ElectrumMnemonic.decode(draft.importText, passphrase: vector.password)
                check(formattedMaterial == canonicalMaterial, "Formatting cleanup derives identical Electrum seed material")
            }
            draft.text = String(repeating: " ", count: 4_096) + vector.phrase
            check(draft.electrumKind == nil, "Formatting cleanup cannot bypass the Electrum input bound")
        }
        check(electrumKinds.count == 5, "All supported Electrum formats retain their decoding rules")
        for hex in [String(repeating: "0", count: 32), String(repeating: "1", count: 64), "0123456789abcdef0123456789abcdef"] {
            draft.replace(with: hex)
            check(draft.electrumKind == .old && draft.importText == hex, "Legacy hex recovery material is never treated as list numbering")
        }
        let aezeedURL = root.appendingPathComponent("Packages/OathAezeed/Tests/OathAezeedTests/Fixtures/lnd-production.json")
        for (index, vector) in try JSONDecoder().decode([SeedVector].self, from: Data(contentsOf: aezeedURL)).enumerated() {
            let words = vector.phrase.split(whereSeparator: \.isWhitespace).map(String.init)
            for input in formatted(words) {
                check(draft.receiveScan(input) && draft.isAezeed && draft.submit() == nil, "Formatted aezeed input still requires authenticated decoding")
                check(draft.importText == vector.phrase, "Aezeed decoding receives the reference words")
            }
            if index == 0 {
                let canonicalMaterial = try Aezeed.decode(vector.phrase, passphrase: vector.password)
                let formattedMaterial = try Aezeed.decode(draft.importText, passphrase: vector.password)
                check(formattedMaterial == canonicalMaterial, "Formatting cleanup derives identical aezeed material")
            }
            draft.text = String(repeating: " ", count: 4_096) + vector.phrase
            check(!draft.isAezeed, "Formatting cleanup cannot bypass the aezeed input bound")
        }

        print("Passed \(checks) host mnemonic/import checks across \(vectorCount) independent vectors, 10 word lists, and all 5 supported lengths.")
    }
}
