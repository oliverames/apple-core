import Contacts
import Ontology

/// Helper for working with contact label constants.
///
/// The mapping runs both ways. Writes need caller tokens turned into the
/// platform constants Contacts stores, and the labeled-value merge needs the
/// reverse, so that a caller who says "home" matches an entry the address
/// book records as `_$!<Home>!$_` instead of appending a second one.
enum CNContactLabel {
    static func from(string: String) -> String {
        switch string.lowercased() {
        case "mobile": return CNLabelPhoneNumberMobile
        case "work": return CNLabelWork
        case "home": return CNLabelHome
        case "other": return CNLabelOther
        case "homepage", "home page": return CNLabelURLAddressHomePage
        case "spouse": return CNLabelContactRelationSpouse
        case "partner": return CNLabelContactRelationPartner
        case "child": return CNLabelContactRelationChild
        case "parent": return CNLabelContactRelationParent
        case "mother": return CNLabelContactRelationMother
        case "father": return CNLabelContactRelationFather
        case "brother": return CNLabelContactRelationBrother
        case "sister": return CNLabelContactRelationSister
        case "friend": return CNLabelContactRelationFriend
        case "manager": return CNLabelContactRelationManager
        case "assistant": return CNLabelContactRelationAssistant
        default: return string
        }
    }

    /// The caller-facing token for a stored label. Unknown and custom labels
    /// pass through unchanged rather than being flattened to "other".
    static func token(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case CNLabelPhoneNumberMobile: return "mobile"
        case CNLabelWork: return "work"
        case CNLabelHome: return "home"
        case CNLabelOther: return "other"
        case CNLabelURLAddressHomePage: return "homepage"
        case CNLabelContactRelationSpouse: return "spouse"
        case CNLabelContactRelationPartner: return "partner"
        case CNLabelContactRelationChild: return "child"
        case CNLabelContactRelationParent: return "parent"
        case CNLabelContactRelationMother: return "mother"
        case CNLabelContactRelationFather: return "father"
        case CNLabelContactRelationBrother: return "brother"
        case CNLabelContactRelationSister: return "sister"
        case CNLabelContactRelationFriend: return "friend"
        case CNLabelContactRelationManager: return "manager"
        case CNLabelContactRelationAssistant: return "assistant"
        default: return raw
        }
    }
}

/// Turns the `{label: value}` object the richer write fields accept into the
/// change list the merge understands. A JSON null is a deletion request; any
/// other non-string value is refused rather than silently ignored.
private func labeledChanges(
    from value: Value?,
    field: String
) throws -> [ContactLabeledValueChange]? {
    guard let value else { return nil }
    guard case let .object(entries) = value else {
        throw NSError(
            domain: "ContactsService",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(field) must be an object of label to value, such as {\"home\": \"...\"}. "
                    + "Pass null as a value to remove that label."
            ]
        )
    }
    return try entries.keys.sorted().map { key in
        switch entries[key] {
        case .string(let text):
            return ContactLabeledValueChange(label: key, value: text)
        case .null, .none:
            return ContactLabeledValueChange(label: key, value: nil)
        default:
            throw NSError(
                domain: "ContactsService",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(field)[\(key)] must be a string, or null to remove it."
                ]
            )
        }
    }
}

extension CNMutableContact {
    /// Populate a contact from provided arguments dictionary
    func populate(from arguments: [String: Value]) throws {
        // Set given name
        if case let .string(givenName) = arguments["givenName"] {
            self.givenName = givenName
        }

        // Set family name
        if case let .string(familyName) = arguments["familyName"] {
            self.familyName = familyName
        }

        // Set organization name
        if case let .string(organizationName) = arguments["organizationName"] {
            self.organizationName = organizationName
        }

        // Set job title
        if case let .string(jobTitle) = arguments["jobTitle"] {
            self.jobTitle = jobTitle
        }

        // Set phone numbers
        // Merged, not assigned. Assigning replaced the whole list, so on an
        // update "add his work number" silently dropped his mobile and home
        // ones and synced the loss to every device. An unmentioned label is
        // left alone; an explicit null is the only way to remove one.
        if let changes = try labeledChanges(from: arguments["phoneNumbers"], field: "phoneNumbers") {
            let existing = self.phoneNumbers.map { entry in
                ContactLabeledValue(
                    label: CNContactLabel.token(for: entry.label),
                    rawLabel: entry.label,
                    value: entry.value.stringValue
                )
            }
            let merged = try ContactLabeledValueWrites.merge(
                existing: existing,
                changes: changes,
                field: "phoneNumbers"
            )
            self.phoneNumbers = merged.map { entry in
                CNLabeledValue(
                    label: entry.rawLabel ?? CNContactLabel.from(string: entry.label ?? "other"),
                    value: CNPhoneNumber(stringValue: entry.value)
                )
            }
        }

        // Set email addresses
        if let changes = try labeledChanges(
            from: arguments["emailAddresses"],
            field: "emailAddresses"
        ) {
            let existing = self.emailAddresses.map { entry in
                ContactLabeledValue(
                    label: CNContactLabel.token(for: entry.label),
                    rawLabel: entry.label,
                    value: entry.value as String
                )
            }
            let merged = try ContactLabeledValueWrites.merge(
                existing: existing,
                changes: changes,
                field: "emailAddresses"
            )
            self.emailAddresses = merged.map { entry in
                CNLabeledValue(
                    label: entry.rawLabel ?? CNContactLabel.from(string: entry.label ?? "other"),
                    value: entry.value as NSString
                )
            }
        }

        // Merged by label, for the same reason as phone and email: assigning
        // the whole list meant updating one address deleted the others. Which
        // entries survive is decided by ContactStructuredMerge so that part is
        // testable without the Contacts framework.
        if case let .object(postalAddresses) = arguments["postalAddresses"] {
            let keys = Array(postalAddresses.keys)
            var removed: Set<String> = []
            for key in keys {
                if case .null = postalAddresses[key] { removed.insert(key) }
            }
            let steps = ContactStructuredMerge.plan(
                existingLabels: self.postalAddresses.map { CNContactLabel.token(for: $0.label) },
                changeKeys: keys,
                removedKeys: removed
            )
            var merged: [CNLabeledValue<CNPostalAddress>] = []
            for step in steps {
                switch step {
                case let .keep(index):
                    merged.append(self.postalAddresses[index])
                case let .remove(index):
                    _ = index
                case let .replace(index, changeKey):
                    guard case let .object(data) = postalAddresses[changeKey] else {
                        merged.append(self.postalAddresses[index])
                        continue
                    }
                    merged.append(
                        CNLabeledValue(
                            label: self.postalAddresses[index].label,
                            value: Self.postalAddress(from: data)
                        )
                    )
                case let .append(changeKey):
                    guard case let .object(data) = postalAddresses[changeKey] else { continue }
                    merged.append(
                        CNLabeledValue(
                            label: CNContactLabel.from(string: changeKey),
                            value: Self.postalAddress(from: data)
                        )
                    )
                }
            }
            self.postalAddresses = merged
        }

        // Set nickname
        if case let .string(nickname) = arguments["nickname"] {
            self.nickname = nickname
        }

        // Richer labeled fields, merged rather than replaced: an update that
        // names one label must not delete the others.
        if let changes = try labeledChanges(from: arguments["urlAddresses"], field: "urlAddresses") {
            let existing = self.urlAddresses.map { entry in
                ContactLabeledValue(
                    label: CNContactLabel.token(for: entry.label),
                    rawLabel: entry.label,
                    value: entry.value as String
                )
            }
            let merged = try ContactLabeledValueWrites.merge(
                existing: existing,
                changes: changes,
                field: "urlAddresses"
            )
            self.urlAddresses = merged.map { entry in
                CNLabeledValue(
                    label: entry.rawLabel ?? CNContactLabel.from(string: entry.label ?? "other"),
                    value: entry.value as NSString
                )
            }
        }

        if let changes = try labeledChanges(from: arguments["socialProfiles"], field: "socialProfiles") {
            // The service is the label here, because that is how a caller
            // thinks about it: one Mastodon handle, one LinkedIn profile.
            let existing = self.socialProfiles.map { entry in
                let service = entry.value.service
                let username = entry.value.username
                return ContactLabeledValue(
                    label: service.isEmpty
                        ? (CNContactLabel.token(for: entry.label) ?? "other") : service,
                    rawLabel: entry.label,
                    value: username.isEmpty ? entry.value.urlString : username
                )
            }
            let merged = try ContactLabeledValueWrites.merge(
                existing: existing.filter { !$0.value.isEmpty },
                changes: changes,
                field: "socialProfiles"
            )
            self.socialProfiles = merged.map { entry in
                let service = entry.label ?? "other"
                // A value that looks like a link is stored as one, so the card
                // opens in a browser rather than showing a bare handle.
                let isURL = entry.value.lowercased().hasPrefix("http")
                let profile = CNSocialProfile(
                    urlString: isURL ? entry.value : nil,
                    username: isURL ? nil : entry.value,
                    userIdentifier: nil,
                    service: service
                )
                return CNLabeledValue(label: entry.rawLabel ?? service, value: profile)
            }
        }

        if let changes = try labeledChanges(from: arguments["relations"], field: "relations") {
            let existing = self.contactRelations.map { entry in
                ContactLabeledValue(
                    label: CNContactLabel.token(for: entry.label),
                    rawLabel: entry.label,
                    value: entry.value.name
                )
            }
            let merged = try ContactLabeledValueWrites.merge(
                existing: existing,
                changes: changes,
                field: "relations"
            )
            self.contactRelations = merged.map { entry in
                CNLabeledValue(
                    label: entry.rawLabel ?? CNContactLabel.from(string: entry.label ?? "other"),
                    value: CNContactRelation(name: entry.value)
                )
            }
        }

        // Set or clear the photo. Validation happens before anything is
        // saved, so a malformed image cannot reach the card.
        if let photoValue = arguments["photoBase64"] {
            switch photoValue {
            case .string(let base64) where !base64.trimmingCharacters(in: .whitespaces).isEmpty:
                self.imageData = try ContactPhotoWrite.decode(base64: base64).data
            case .null:
                self.imageData = nil
            case .string:
                self.imageData = nil
            default:
                throw NSError(
                    domain: "ContactsService",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "photoBase64 must be a base64 string, or null to remove the photo."
                    ]
                )
            }
        }

        // Set birthday
        if case let .object(birthdayData) = arguments["birthday"],
            case let .int(day) = birthdayData["day"],
            case let .int(month) = birthdayData["month"]
        {
            // Validate here rather than at save time, where an out-of-range
            // component surfaces as an opaque framework error.
            guard (1 ... 12).contains(month), (1 ... 31).contains(day) else {
                throw NSError(
                    domain: "ContactsService",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Birthday month must be 1-12 and day must be 1-31 (got month \(month), day \(day))."
                    ]
                )
            }

            var dateComponents = DateComponents()
            dateComponents.day = day
            dateComponents.month = month

            if case let .int(year) = birthdayData["year"] {
                dateComponents.year = year
            }

            self.birthday = dateComponents
        }
    }

    /// Builds a postal address from a change object, leaving any component the
    /// caller did not name empty.
    fileprivate static func postalAddress(from data: [String: Value]) -> CNPostalAddress {
        let address = CNMutablePostalAddress()
        if case let .string(street) = data["street"] { address.street = street }
        if case let .string(city) = data["city"] { address.city = city }
        if case let .string(state) = data["state"] { address.state = state }
        if case let .string(postalCode) = data["postalCode"] { address.postalCode = postalCode }
        if case let .string(country) = data["country"] { address.country = country }
        return address
    }

}
