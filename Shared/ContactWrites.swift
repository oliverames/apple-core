// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure write-shaping for Contacts: labeled-value merging, group naming, and
// photo payload validation.
//
// The dangerous part of widening a contact's writable schema is not setting
// the new field, it is what happens to the fields nobody mentioned. A naive
// "replace the array" write turns "add his Bluesky handle" into "delete his
// Twitter, LinkedIn and personal site". So every labeled write goes through
// `ContactLabeledValueWrites.merge`, which only ever touches the labels the
// caller named, and deletion is something the caller has to ask for by
// passing an explicit null.
//
// None of this imports Contacts. The service converts `CNLabeledValue`s into
// `ContactLabeledValue` values, merges here, and converts back, which is what
// lets the preservation rule be tested without an address book.

import Foundation

// MARK: - Labeled values

/// One labeled entry on a contact, as the merge sees it.
///
/// `label` is the caller-facing token ("home", "work", "bluesky"). `rawLabel`
/// is whatever the platform stored, kept verbatim so a preserved entry is
/// written back exactly as it was found rather than being re-derived from the
/// token and quietly relabeled.
public struct ContactLabeledValue: Sendable, Equatable {
    public let label: String?
    public let rawLabel: String?
    public let value: String

    public init(label: String?, rawLabel: String? = nil, value: String) {
        self.label = label
        self.rawLabel = rawLabel
        self.value = value
    }
}

/// One requested change. A nil `value` deletes that label; it is the only way
/// to remove an entry, so nothing is ever deleted by omission.
public struct ContactLabeledValueChange: Sendable, Equatable {
    public let label: String
    public let value: String?

    public init(label: String, value: String?) {
        self.label = label
        self.value = value
    }
}

public enum ContactWriteError: Error, Equatable, CustomStringConvertible {
    case blankLabel(field: String)
    case blankGroupName
    case groupNameTooLong(limit: Int)
    case emptyPhoto
    case photoNotBase64
    case photoTooLarge(bytes: Int, limit: Int)
    case unsupportedPhotoFormat

    public var description: String {
        switch self {
        case .blankLabel(let field):
            return "Every \(field) entry needs a non-empty label, such as \"home\" or \"work\"."
        case .blankGroupName:
            return "A group name is required and cannot be only whitespace."
        case .groupNameTooLong(let limit):
            return "A group name must be \(limit) characters or fewer."
        case .emptyPhoto:
            return "The photo was empty."
        case .photoNotBase64:
            return "The photo must be base64-encoded image data."
        case .photoTooLarge(let bytes, let limit):
            return "The photo is \(bytes) bytes; the limit is \(limit) bytes (about \(limit / 1_048_576)MB)."
        case .unsupportedPhotoFormat:
            return "The photo must be a PNG, JPEG, HEIC or GIF image."
        }
    }
}

public enum ContactLabeledValueWrites {
    /// Applies `changes` to `existing`, leaving every unmentioned label alone.
    ///
    /// Rules, in the order they matter:
    /// 1. A label the caller did not name is preserved untouched, with its
    ///    original platform label.
    /// 2. A named label with a value replaces that entry in place, so the
    ///    ordering the user sees in Contacts does not shuffle on every edit.
    /// 3. A named label with a nil value removes that entry.
    /// 4. A named label that does not exist yet is appended.
    ///
    /// Label comparison is case- and whitespace-insensitive, so "Home" from a
    /// caller matches "home" on the card.
    public static func merge(
        existing: [ContactLabeledValue],
        changes: [ContactLabeledValueChange],
        field: String
    ) throws -> [ContactLabeledValue] {
        var normalizedChanges: [(key: String, change: ContactLabeledValueChange)] = []
        for change in changes {
            let key = normalizeLabel(change.label)
            guard !key.isEmpty else { throw ContactWriteError.blankLabel(field: field) }
            // A repeated label in one request keeps the last value rather than
            // writing the entry twice.
            normalizedChanges.removeAll { $0.key == key }
            normalizedChanges.append((key, change))
        }
        guard !normalizedChanges.isEmpty else { return existing }

        var remaining = normalizedChanges
        var merged: [ContactLabeledValue] = []

        for entry in existing {
            let key = normalizeLabel(entry.label ?? "")
            guard let index = remaining.firstIndex(where: { $0.key == key }) else {
                merged.append(entry)
                continue
            }
            let change = remaining.remove(at: index).change
            guard let value = change.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                // Explicit deletion: the entry is dropped.
                continue
            }
            merged.append(
                ContactLabeledValue(
                    label: entry.label,
                    rawLabel: entry.rawLabel,
                    value: value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        for pending in remaining {
            guard let value = pending.change.value,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                // Deleting something that is not there is a no-op, not an error:
                // the requested end state already holds.
                continue
            }
            merged.append(
                ContactLabeledValue(
                    label: pending.change.label.trimmingCharacters(in: .whitespacesAndNewlines),
                    rawLabel: nil,
                    value: value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        return merged
    }

    public static func normalizeLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Group naming

public enum ContactGroupName {
    /// Contacts itself accepts longer names, but a name this long is almost
    /// always a paste accident, and the group list becomes unreadable.
    public static let maximumLength = 255

    public static func normalize(_ raw: String?) throws -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContactWriteError.blankGroupName }
        guard trimmed.count <= maximumLength else {
            throw ContactWriteError.groupNameTooLong(limit: maximumLength)
        }
        return trimmed
    }
}

// MARK: - Photos

public enum ContactPhotoFormat: String, Sendable, Equatable {
    case png
    case jpeg
    case heic
    case gif
}

public struct ContactPhotoPayload: Sendable, Equatable {
    public let data: Data
    public let format: ContactPhotoFormat

    public init(data: Data, format: ContactPhotoFormat) {
        self.data = data
        self.format = format
    }
}

public enum ContactPhotoWrite {
    /// Contacts stores the image inside the card, and a card that syncs to
    /// every device is the wrong place for an 8MB original.
    public static let maximumBytes = 6 * 1_024 * 1_024

    /// Decodes and checks a base64 photo before anything is saved.
    ///
    /// The format is read from the file's own magic bytes rather than from a
    /// caller-supplied type, because a mislabeled blob saved into a contact
    /// shows up as a broken card on every synced device.
    public static func decode(base64: String) throws -> ContactPhotoPayload {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContactWriteError.emptyPhoto }
        guard
            let data = Data(
                base64Encoded: trimmed,
                options: [.ignoreUnknownCharacters]
            ), !data.isEmpty
        else {
            throw ContactWriteError.photoNotBase64
        }
        guard data.count <= maximumBytes else {
            throw ContactWriteError.photoTooLarge(bytes: data.count, limit: maximumBytes)
        }
        guard let format = self.format(of: data) else {
            throw ContactWriteError.unsupportedPhotoFormat
        }
        return ContactPhotoPayload(data: data, format: format)
    }

    public static func format(of data: Data) -> ContactPhotoFormat? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: Array("GIF8".utf8)) { return .gif }
        if bytes.count >= 12, Array(bytes[4 ..< 8]) == Array("ftyp".utf8) {
            let brand = String(decoding: bytes[8 ..< 12], as: UTF8.self)
            if brand.hasPrefix("hei") || brand.hasPrefix("mif") || brand.hasPrefix("msf") {
                return .heic
            }
        }
        return nil
    }
}

/// What should happen to one existing labeled entry during a merge.
public enum ContactMergeStep: Sendable, Equatable {
    /// The caller did not mention this label, so it survives untouched.
    case keep(index: Int)
    /// The caller named this label, so its value is replaced in place and the
    /// ordering the user sees in Contacts does not shuffle.
    case replace(index: Int, changeKey: String)
    /// The caller named this label with an explicit null.
    case remove(index: Int)
    /// A label the card did not have yet.
    case append(changeKey: String)
}

/// Decides which existing entries survive a structured merge, for fields whose
/// values are too rich for `ContactLabeledValueWrites` to carry.
///
/// This exists so the part that can lose a user's data, which entries survive,
/// is testable without the Contacts framework. Postal addresses were assigned
/// wholesale, which meant editing one address deleted the rest and synced the
/// loss everywhere.
public enum ContactStructuredMerge {
    public static func plan(
        existingLabels: [String?],
        changeKeys: [String],
        removedKeys: Set<String> = []
    ) -> [ContactMergeStep] {
        var unusedKeys = changeKeys
        var steps: [ContactMergeStep] = []

        for (index, label) in existingLabels.enumerated() {
            let token = normalizeLabel(label ?? "")
            guard
                let matchIndex = unusedKeys.firstIndex(where: { normalizeLabel($0) == token }),
                !token.isEmpty
            else {
                steps.append(.keep(index: index))
                continue
            }
            let key = unusedKeys.remove(at: matchIndex)
            steps.append(
                removedKeys.contains(key)
                    ? .remove(index: index)
                    : .replace(index: index, changeKey: key)
            )
        }

        // A removal naming a label the card does not have is a no-op, not an
        // append of nothing.
        for key in unusedKeys where !removedKeys.contains(key) {
            steps.append(.append(changeKey: key))
        }
        return steps
    }

    private static func normalizeLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
