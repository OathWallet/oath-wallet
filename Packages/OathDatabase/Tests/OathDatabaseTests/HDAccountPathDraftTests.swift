import XCTest
@testable import OathDatabase

final class HDAccountPathDraftTests: XCTestCase {
    func testDefaultDraftsAllocateUnusedPathsForBothFamilies() throws {
        for family in HDAccountFamily.allCases {
            let first = try family.nextDefaultPath(existing: [])
            let second = HDAccountPathDraft(family: family, excluding: [first])
            XCTAssertEqual(second.canonicalPath, try family.nextDefaultPath(existing: [first]))
            let third = HDAccountPathDraft(family: family, excluding: [first, try XCTUnwrap(second.canonicalPath)])
            XCTAssertEqual(try HDAccountPathDraft.paths([second, third], family: family).count, 2)
        }
    }

    func testEVMAccountAndAddressIndexAreIndependent() throws {
        var draft = try HDAccountPathDraft(family: .evm, path: "m/44'/60'/0'/0/1")
        let id = draft.id
        draft.setDigits("12", at: 2)
        draft.increment(at: 4)
        XCTAssertEqual(draft.canonicalPath, "m/44'/60'/12'/0/2")
        draft.decrement(at: 2)
        draft.setHardened(true, at: 4)
        XCTAssertEqual(draft.canonicalPath, "m/44'/60'/11'/0/2'")
        XCTAssertEqual(draft.id, id)
    }

    func testSolanaAccountCanChangeButCannotBecomeUnhardened() throws {
        var draft = try HDAccountPathDraft(family: .solana, path: "m/44'/501'/0'/0'")
        draft.increment(at: 2)
        draft.setHardened(false, at: 2)
        draft.appendComponent()
        XCTAssertEqual(draft.canonicalPath, "m/44'/501'/1'/0'/0'")
        XCTAssertTrue(draft.components.allSatisfy(\.hardened))
        XCTAssertThrowsError(try HDAccountPathDraft(family: .solana, path: "m/44'/501'/0'/0"))
    }

    func testIncrementAndDecrementCannotCrossBIP32Bounds() throws {
        var draft = try HDAccountPathDraft(family: .evm, path: "m/0")
        draft.decrement(at: 0)
        XCTAssertEqual(draft.canonicalPath, "m/0")
        draft.setDigits("2147483647", at: 0)
        draft.increment(at: 0)
        XCTAssertEqual(draft.canonicalPath, "m/2147483647")
        draft.decrement(at: 0)
        XCTAssertEqual(draft.canonicalPath, "m/2147483646")
    }

    func testInvalidAndUnfinishedInputNeverSilentlyChangesThePath() throws {
        for value in ["", "-1", "+1", "1/2", "1'", "2147483648", "abc", "1.5", "²", "1\n2"] {
            var draft = try HDAccountPathDraft(family: .evm, path: "m/0")
            draft.setDigits(value, at: 0)
            draft.increment(at: 0); draft.decrement(at: 0)
            XCTAssertEqual(draft.components[0].digits, value)
            XCTAssertNil(draft.canonicalPath, value)
            XCTAssertThrowsError(try HDAccountPathDraft.paths([draft], family: .evm), value)
        }
    }

    func testLocalizedDecimalDigitsBecomeTheSameExplicitIndex() throws {
        var draft = try HDAccountPathDraft(family: .evm, path: "m/0")
        for value in ["١٢٣", "۱۲۳", "१२३", "１２３", "00123"] {
            draft.setDigits(value, at: 0)
            XCTAssertEqual(draft.canonicalPath, "m/123", value)
        }
    }

    func testCustomDepthKeepsOneToTenComponentsAndPreservesPrefixes() throws {
        var draft = try HDAccountPathDraft(family: .evm, path: "m/49'/60'/9'")
        for _ in 0..<12 { draft.appendComponent() }
        XCTAssertEqual(draft.components.count, 10)
        XCTAssertEqual(draft.canonicalPath, "m/49'/60'/9'/0/0/0/0/0/0/0")
        for _ in 0..<12 { draft.removeLastComponent() }
        XCTAssertEqual(draft.canonicalPath, "m/49'")
        draft.setDigits("4", at: -1); draft.increment(at: 10); draft.decrement(at: 10)
        XCTAssertEqual(draft.canonicalPath, "m/49'")
    }

    func testBatchRetainsCanonicalDuplicateAndTwentyPathGuards() throws {
        let twenty = try (0..<20).map { try HDAccountPathDraft(family: .evm, path: "m/\($0)") }
        XCTAssertEqual(try HDAccountPathDraft.paths(twenty, family: .evm).count, 20)
        XCTAssertThrowsError(try HDAccountPathDraft.paths([], family: .evm))
        XCTAssertThrowsError(try HDAccountPathDraft.paths(twenty + [twenty[0]], family: .evm))
        var duplicate = twenty[0]
        duplicate.setDigits("0000", at: 0)
        XCTAssertThrowsError(try HDAccountPathDraft.paths([twenty[0], duplicate], family: .evm))
        XCTAssertThrowsError(try HDAccountPathDraft.paths(twenty, family: .solana))
    }

    func testAutomaticNumberLimitStillAllowsCustomEditing() throws {
        let used = Set((0..<1024).map { "m/44'/60'/0'/0/\($0)" })
        var draft = HDAccountPathDraft(family: .evm, excluding: used)
        draft.setDigits("2048", at: 4)
        XCTAssertEqual(draft.canonicalPath, "m/44'/60'/0'/0/2048")
    }
}
