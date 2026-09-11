// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// These tests exist for one reason: a write that widens a contact's schema
/// must never take away a value nobody mentioned. They run entirely over
/// fabricated labeled values, and touch no address book.
@Suite("Contact writes")
struct ContactWritesTests {
    // MARK: Labeled value merging

    static let existingURLs = [
        ContactLabeledValue(label: "homepage", rawLabel: "_$!<HomePage>!$_", value: "https://a.example"),
        ContactLabeledValue(label: "work", rawLabel: "_$!<Work>!$_", value: "https://b.example"),
    ]

    @Test("Adding one label leaves every other label untouched")
    func addingPreservesOthers() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: Self.existingURLs,
            changes: [ContactLabeledValueChange(label: "blog", value: "https://c.example")],
            field: "urlAddresses"
        )
        #expect(merged.count == 3)
        #expect(merged[0] == Self.existingURLs[0])
        #expect(merged[1] == Self.existingURLs[1])
        #expect(merged[2].label == "blog")
        #expect(merged[2].rawLabel == nil)
    }

    @Test("Changing one label replaces it in place and keeps its platform label")
    func replacingKeepsRawLabel() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: Self.existingURLs,
            changes: [ContactLabeledValueChange(label: "work", value: "https://new.example")],
            field: "urlAddresses"
        )
        #expect(merged.count == 2)
        #expect(merged[1].value == "https://new.example")
        #expect(merged[1].rawLabel == "_$!<Work>!$_")
        #expect(merged[0] == Self.existingURLs[0])
    }

    @Test("Label matching ignores case, so \"Work\" does not append a second entry")
    func labelMatchingIsCaseInsensitive() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: Self.existingURLs,
            changes: [ContactLabeledValueChange(label: "  WORK ", value: "https://new.example")],
            field: "urlAddresses"
        )
        #expect(merged.count == 2)
        #expect(merged[1].value == "https://new.example")
    }

    @Test("Only an explicit null deletes an entry")
    func nullDeletes() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: Self.existingURLs,
            changes: [ContactLabeledValueChange(label: "work", value: nil)],
            field: "urlAddresses"
        )
        #expect(merged.count == 1)
        #expect(merged[0].label == "homepage")
    }

    @Test("An empty string is treated as a deletion rather than stored as blank")
    func emptyStringDeletes() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: Self.existingURLs,
            changes: [ContactLabeledValueChange(label: "work", value: "   ")],
            field: "urlAddresses"
        )
        #expect(merged.map(\.label) == ["homepage"])
    }

    @Test("Deleting a label that is not there changes nothing and does not throw")
    func deletingAbsentLabelIsANoOp() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: Self.existingURLs,
            changes: [ContactLabeledValueChange(label: "school", value: nil)],
            field: "urlAddresses"
        )
        #expect(merged == Self.existingURLs)
    }

    @Test("No changes leaves the list exactly as it was")
    func emptyChangeSetIsIdentity() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: Self.existingURLs,
            changes: [],
            field: "urlAddresses"
        )
        #expect(merged == Self.existingURLs)
    }

    @Test("A repeated label in one request writes one entry, not two")
    func repeatedLabelCollapses() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: [],
            changes: [
                ContactLabeledValueChange(label: "home", value: "https://first.example"),
                ContactLabeledValueChange(label: "Home", value: "https://second.example"),
            ],
            field: "urlAddresses"
        )
        #expect(merged.count == 1)
        #expect(merged[0].value == "https://second.example")
    }

    @Test("Values are trimmed before they are stored")
    func trimsValues() throws {
        let merged = try ContactLabeledValueWrites.merge(
            existing: [],
            changes: [ContactLabeledValueChange(label: "home", value: "  https://x.example \n")],
            field: "urlAddresses"
        )
        #expect(merged[0].value == "https://x.example")
    }

    @Test("A blank label is refused rather than written as an unnamed entry")
    func blankLabelRefused() {
        #expect(throws: ContactWriteError.blankLabel(field: "relations")) {
            _ = try ContactLabeledValueWrites.merge(
                existing: [],
                changes: [ContactLabeledValueChange(label: "   ", value: "Robin")],
                field: "relations"
            )
        }
    }

    @Test("Custom labels the caller invented survive a later unrelated edit")
    func customLabelsSurvive() throws {
        let existing = [
            ContactLabeledValue(label: "ham radio", rawLabel: "ham radio", value: "W1AW")
        ]
        let merged = try ContactLabeledValueWrites.merge(
            existing: existing,
            changes: [ContactLabeledValueChange(label: "work", value: "https://w.example")],
            field: "urlAddresses"
        )
        #expect(merged.first == existing.first)
    }

    // MARK: Group names

    @Test("Group names are trimmed")
    func groupNameTrimmed() throws {
        #expect(try ContactGroupName.normalize("  Book Club  ") == "Book Club")
    }

    @Test("A blank group name is refused")
    func blankGroupNameRefused() {
        #expect(throws: ContactWriteError.blankGroupName) {
            _ = try ContactGroupName.normalize("   ")
        }
        #expect(throws: ContactWriteError.blankGroupName) {
            _ = try ContactGroupName.normalize(nil)
        }
    }

    @Test("An absurdly long group name is refused before it reaches the store")
    func longGroupNameRefused() {
        let long = String(repeating: "x", count: ContactGroupName.maximumLength + 1)
        #expect(throws: ContactWriteError.groupNameTooLong(limit: ContactGroupName.maximumLength)) {
            _ = try ContactGroupName.normalize(long)
        }
    }

    // MARK: Photos

    static func base64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    @Test("A PNG is recognized from its own bytes")
    func decodesPNG() throws {
        let png = Self.base64([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        #expect(try ContactPhotoWrite.decode(base64: png).format == .png)
    }

    @Test("A JPEG is recognized from its own bytes")
    func decodesJPEG() throws {
        let jpeg = Self.base64([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])
        #expect(try ContactPhotoWrite.decode(base64: jpeg).format == .jpeg)
    }

    @Test("A HEIC file is recognized by its brand rather than by its name")
    func decodesHEIC() throws {
        var bytes: [UInt8] = [0, 0, 0, 0x18]
        bytes.append(contentsOf: Array("ftyp".utf8))
        bytes.append(contentsOf: Array("heic".utf8))
        #expect(try ContactPhotoWrite.decode(base64: Self.base64(bytes)).format == .heic)
    }

    @Test("Text claiming to be a photo is refused rather than saved to the card")
    func refusesNonImage() {
        let text = Data("this is not an image at all".utf8).base64EncodedString()
        #expect(throws: ContactWriteError.unsupportedPhotoFormat) {
            _ = try ContactPhotoWrite.decode(base64: text)
        }
    }

    @Test("Data that is not base64 at all is refused")
    func refusesNonBase64() {
        #expect(throws: ContactWriteError.photoNotBase64) {
            _ = try ContactPhotoWrite.decode(base64: "!!!!")
        }
    }

    @Test("An empty photo is refused")
    func refusesEmptyPhoto() {
        #expect(throws: ContactWriteError.emptyPhoto) {
            _ = try ContactPhotoWrite.decode(base64: "   ")
        }
    }

    @Test("A photo over the size cap is refused before it can sync everywhere")
    func refusesOversizePhoto() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: ContactPhotoWrite.maximumBytes + 8))
        #expect(throws: ContactWriteError.self) {
            _ = try ContactPhotoWrite.decode(base64: Self.base64(bytes))
        }
    }
}
