import SwiftUI
import OathDatabase

/// Hold real SwiftUI row bindings past removal, as a retiring number pad/control
/// can do. Run without a window or a simulator; all paths are synthetic fixtures.
@main struct CheckHDPathBindings {
    @MainActor private final class Source {
        var drafts: [HDAccountPathDraft]
        var writes = 0
        var transaction = Transaction()
        init(_ drafts: [HDAccountPathDraft]) { self.drafts = drafts }
        var binding: Binding<[HDAccountPathDraft]> {
            Binding(get: { self.drafts }, set: { value, transaction in
                self.drafts = value; self.transaction = transaction; self.writes += 1
            })
        }
    }

    private struct Row: View {
        let draft: Binding<HDAccountPathDraft>
        var body: some View { EmptyView() }
    }

    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }

        for family in HDAccountFamily.allCases {
            var used = Set<String>()
            let fixtures = (0..<3).map { _ in
                let draft = HDAccountPathDraft(family: family, excluding: used)
                used.insert(draft.canonicalPath!)
                return draft
            }
            let source = Source(fixtures)
            let rows = ForEach(source.drafts) { snapshot in
                Row(draft: OathHDPathBindings.draft(snapshot, in: source.binding))
            }
            let retained = rows.data.map { rows.content($0).draft }
            let fieldIndex = fixtures[0].components.count - 1

            // A live number-pad edit must reach the correct source immediately.
            let numberPad = Binding<String>(get: {
                retained[1].wrappedValue.components[fieldIndex].digits
            }, set: { retained[1].wrappedValue.setDigits($0, at: fieldIndex) })
            numberPad.wrappedValue = "27"
            check(source.drafts[1].components[fieldIndex].digits == "27", "Live number-pad edit lost")
            check(source.drafts[0] == fixtures[0] && source.drafts[2] == fixtures[2], "Editing changed siblings")
            source.drafts[1].setDigits("28", at: fieldIndex)
            check(numberPad.wrappedValue == "28", "Retained binding must read the latest live value")

            // This is the same state transition as the successful blue-checkmark
            // import: validate captured paths, await save, then clear the drafts.
            let accepted = try HDAccountPathDraft.paths(source.drafts, family: family)
            check(accepted.count == 3 && accepted[1] == source.drafts[1].canonicalPath, "Import snapshot changed")
            source.drafts.removeAll()
            for (index, binding) in retained.enumerated() {
                check(binding.wrappedValue.id == fixtures[index].id, "Retired row read lost identity")
                binding.wrappedValue.increment(at: fieldIndex)
                binding.wrappedValue.setHardened(true, at: fieldIndex)
            }
            numberPad.wrappedValue = "29"
            check(source.drafts.isEmpty, "Late keyboard/Stepper/Toggle callback resurrected an imported draft")
            check(accepted.count == 3, "Retiring UI changed the accepted import snapshot")

            // Deleting an earlier row moves array positions. Existing controls
            // must keep editing their original ID, never the row now at that index.
            source.drafts = fixtures
            source.drafts.removeFirst()
            numberPad.wrappedValue = "31"
            check(source.drafts[0].id == fixtures[1].id && source.drafts[0].components[fieldIndex].digits == "31", "Shifted row edited the wrong path")
            check(source.drafts[1] == fixtures[2], "Shifted row overwrote its sibling")
            let survivors = source.drafts
            retained[0].wrappedValue.setDigits("99", at: fieldIndex)
            check(source.drafts == survivors, "Deleted row overwrote the next row")

            source.drafts.reverse()
            numberPad.wrappedValue = "32"
            check(source.drafts.first(where: { $0.id == fixtures[1].id })?.components[fieldIndex].digits == "32", "Reordering detached live controls")
            check(source.drafts.first(where: { $0.id == fixtures[2].id }) == fixtures[2], "Reordering changed sibling")

            // Lock also clears the form. A new form may reuse the same path but
            // must have a new identity, independent of retiring controls.
            source.drafts.removeAll()
            let replacement = try HDAccountPathDraft(family: family, path: fixtures[1].canonicalPath!)
            source.drafts = [replacement]
            numberPad.wrappedValue = "100"
            check(source.drafts == [replacement], "Old form edited a new form with the same path")
            check(replacement.id != fixtures[1].id, "Fixture identities must differ")

            source.drafts = fixtures
            var transaction = Transaction()
            transaction.disablesAnimations = true
            var changed = retained[2].wrappedValue
            changed.setDigits("33", at: fieldIndex)
            retained[2].transaction(transaction).wrappedValue = changed
            check(source.drafts[2] == changed, "Explicit binding write lost")
            check(source.transaction.disablesAnimations, "Native transaction was not forwarded")
            let previous = source.drafts
            let writes = source.writes
            retained[2].wrappedValue = replacement
            check(source.drafts == previous && source.writes == writes, "Binding accepted a different draft identity")

            // Retire all controls while their values contain unfinished form
            // input. Neither teardown nor a retry may normalize it into a save.
            numberPad.wrappedValue = ""
            check(source.drafts[1].canonicalPath == nil, "Unfinished number input became a valid path")
            source.drafts.removeAll()
            _ = numberPad.wrappedValue
            numberPad.wrappedValue = "1"
            check(source.drafts.isEmpty, "Unfinished retiring input was reinserted")
        }
        print("HD path bindings: \(checks) checks passed for EVM and Solana (native SwiftUI host, no app launch).")
    }
}
