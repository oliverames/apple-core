import Foundation
import Testing

/// `contacts_update` assigned phone, email and postal lists wholesale, so
/// "add his work number" deleted his mobile and home ones and synced the loss
/// to every device. These pin the rule that decides which entries survive:
/// anything the caller did not name is kept.
@Suite("Contact structured merge")
struct ContactStructuredMergeTests {
    @Test("A label the caller never mentions survives untouched")
    func unmentionedLabelsSurvive() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["home", "mobile", "work"],
            changeKeys: ["work"]
        )
        #expect(
            steps == [
                .keep(index: 0),
                .keep(index: 1),
                .replace(index: 2, changeKey: "work"),
            ]
        )
    }

    @Test("A named label is replaced in place, so the card does not reorder")
    func replacementKeepsPosition() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["home", "work"],
            changeKeys: ["home"]
        )
        #expect(steps.first == .replace(index: 0, changeKey: "home"))
        #expect(steps.last == .keep(index: 1))
    }

    @Test("An explicit null is the only thing that removes an entry")
    func nullRemoves() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["home", "work"],
            changeKeys: ["home"],
            removedKeys: ["home"]
        )
        #expect(steps == [.remove(index: 0), .keep(index: 1)])
    }

    @Test("A label the card does not have yet is appended")
    func newLabelAppends() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["home"],
            changeKeys: ["work"]
        )
        #expect(steps == [.keep(index: 0), .append(changeKey: "work")])
    }

    @Test("Removing a label the card does not have is a no-op, not an empty append")
    func removingAbsentLabelDoesNothing() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["home"],
            changeKeys: ["work"],
            removedKeys: ["work"]
        )
        #expect(steps == [.keep(index: 0)])
    }

    @Test("Label matching ignores case and surrounding whitespace")
    func labelMatchingIsForgiving() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["Home"],
            changeKeys: ["  home "]
        )
        #expect(steps == [.replace(index: 0, changeKey: "  home ")])
    }

    @Test("An entry whose label the platform will not name is kept, never replaced")
    func unlabelledEntriesAreKept() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: [nil, "work"],
            changeKeys: ["work"]
        )
        #expect(steps == [.keep(index: 0), .replace(index: 1, changeKey: "work")])
    }

    @Test("Two existing entries sharing a label consume the change only once")
    func duplicateLabelsConsumeOneChange() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["work", "work"],
            changeKeys: ["work"]
        )
        #expect(steps == [.replace(index: 0, changeKey: "work"), .keep(index: 1)])
    }

    @Test("An empty change set leaves every entry alone")
    func noChangesKeepsEverything() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["home", "work", "mobile"],
            changeKeys: []
        )
        #expect(steps == [.keep(index: 0), .keep(index: 1), .keep(index: 2)])
    }

    @Test("The regression itself: one named label never removes the others")
    func addingOneNumberKeepsTheRest() {
        let steps = ContactStructuredMerge.plan(
            existingLabels: ["mobile", "home"],
            changeKeys: ["work"]
        )
        let survivors = steps.filter {
            if case .keep = $0 { return true }
            return false
        }
        #expect(survivors.count == 2)
        #expect(steps.contains(.append(changeKey: "work")))
    }
}
