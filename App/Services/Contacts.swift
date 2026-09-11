import Contacts
import Foundation
import JSONSchema
import OSLog
import Ontology
import OrderedCollections

private let log = Logger.service("contacts")

private let contactKeys =
    [
        CNContactIdentifierKey,
        CNContactTypeKey,
        CNContactNamePrefixKey,
        CNContactGivenNameKey,
        CNContactMiddleNameKey,
        CNContactFamilyNameKey,
        CNContactNameSuffixKey,
        CNContactPreviousFamilyNameKey,
        CNContactNicknameKey,
        CNContactPhoneticGivenNameKey,
        CNContactPhoneticMiddleNameKey,
        CNContactPhoneticFamilyNameKey,
        CNContactPhoneticOrganizationNameKey,
        CNContactBirthdayKey,
        CNContactNonGregorianBirthdayKey,
        // Anniversaries and any other labelled date. Nothing in this surface
        // could read or write one before, so a contact's anniversary was
        // invisible even though Contacts.app shows it beside the birthday.
        CNContactDatesKey,
        CNContactOrganizationNameKey,
        CNContactDepartmentNameKey,
        CNContactJobTitleKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactInstantMessageAddressesKey,
        CNContactSocialProfilesKey,
        CNContactUrlAddressesKey,
        CNContactPostalAddressesKey,
        CNContactRelationsKey,
        CNContactImageDataAvailableKey,
    ] as [CNKeyDescriptor]
    // CNContactFormatter raises an Objective-C exception, which Swift cannot
    // catch and which aborts the process, if it is handed a contact fetched
    // without the keys it needs. Its requirements are not the public name keys
    // above and are not documented individually, so they have to be asked for.
    // Omitting this crashed the whole connector on a contacts_search.
    + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]

private let contactProperties: OrderedDictionary<String, JSONSchema> = [
    "givenName": .string(),
    "familyName": .string(),
    "organizationName": .string(),
    "jobTitle": .string(),
    "phoneNumbers": .object(
        properties: [
            "mobile": .string(),
            "work": .string(),
            "home": .string(),
        ],
        additionalProperties: true
    ),
    "emailAddresses": .object(
        properties: [
            "work": .string(),
            "home": .string(),
        ],
        additionalProperties: true
    ),
    "postalAddresses": .object(
        properties: [
            "work": .object(
                properties: [
                    "street": .string(),
                    "city": .string(),
                    "state": .string(),
                    "postalCode": .string(),
                    "country": .string(),
                ]
            ),
            "home": .object(
                properties: [
                    "street": .string(),
                    "city": .string(),
                    "state": .string(),
                    "postalCode": .string(),
                    "country": .string(),
                ]
            ),
        ],
        additionalProperties: true
    ),
    "birthday": .object(
        properties: [
            "day": .integer(minimum: 1, maximum: 31),
            "month": .integer(minimum: 1, maximum: 12),
            "year": .integer(),
        ],
        required: ["day", "month"]
    ),
    "nickname": .string(description: "Nickname, as Contacts shows it beside the name"),
    "urlAddresses": .object(
        description:
            "Websites, as label to URL, such as {\"homepage\": \"https://example.com\"}. "
            + "Only the labels named here change; pass null as a value to remove that one.",
        additionalProperties: true
    ),
    "socialProfiles": .object(
        description:
            "Social accounts, as service to handle or profile URL, such as "
            + "{\"Mastodon\": \"@someone@example.social\"}. Only the services named here change; "
            + "pass null as a value to remove one.",
        additionalProperties: true
    ),
    "relations": .object(
        description:
            "Related people, as relationship to name, such as {\"spouse\": \"Robin Vale\"}. "
            + "Known relationships are spouse, partner, child, parent, mother, father, brother, "
            + "sister, friend, manager and assistant; any other word is kept as a custom label. "
            + "Only the relationships named here change; pass null as a value to remove one.",
        additionalProperties: true
    ),
    "photoBase64": .string(
        description:
            "Contact photo as base64-encoded PNG, JPEG, HEIC or GIF data, up to 6MB. "
            + "Pass null to remove the existing photo."
    ),
]

final class ContactsService: Service {
    private let contactStore = CNContactStore()

    static let shared = ContactsService()

    private func runContactStore<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await Task(priority: .utility) {
            try operation()
        }.value
    }

    var isActivated: Bool {
        get async {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            return status == .authorized
        }
    }

    func activate() async throws {
        log.debug("Activating contacts service")
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            log.debug("Contacts access authorized")
            return
        case .denied:
            log.error("Contacts access denied")
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access denied"]
            )
        case .restricted:
            log.error("Contacts access restricted")
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access restricted"]
            )
        case .notDetermined:
            log.debug("Requesting contacts access")
            let granted = try await contactStore.requestAccess(for: .contacts)
            guard granted else {
                let statusAfterRequest = CNContactStore.authorizationStatus(for: .contacts)
                throw ServicePermissionError.requestFailed(
                    domain: "ContactsService",
                    what: "Contacts",
                    promptCouldHaveAppeared: statusAfterRequest != .notDetermined
                )
            }
        @unknown default:
            log.error("Unknown contacts authorization status")
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown contacts authorization status"]
            )
        }
    }

    private static func requiredIdentifier(_ key: String, from arguments: [String: Value]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing required argument: \(key)"]
            )
        }
        return value
    }

    /// One group by identifier, as a live object a save request will accept.
    private func resolveGroup(_ identifier: String) throws -> CNGroup {
        let groups = try contactStore.groups(
            matching: CNGroup.predicateForGroups(withIdentifiers: [identifier])
        )
        guard let group = groups.first else {
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "NOT_FOUND: no group with identifier \(identifier). "
                        + "Use contacts_groups to list current group identifiers."
                ]
            )
        }
        return group
    }

    /// Membership changes need the group and the contact as live objects, and
    /// CNSaveRequest rejects the immutable contact `unifiedContact` returns.
    private func resolveGroupAndContact(
        _ groupID: String,
        _ contactID: String
    ) throws -> (CNGroup, CNContact) {
        let groups = try contactStore.groups(
            matching: CNGroup.predicateForGroups(withIdentifiers: [groupID])
        )
        guard let group = groups.first else {
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No group with identifier \(groupID)"]
            )
        }
        let contact = try contactStore.unifiedContact(
            withIdentifier: contactID,
            keysToFetch: contactKeys
        )
        return (group, contact)
    }

    /// Reads the whole address book once, unified.
    ///
    /// `unifyResults` is left at its default, so records macOS already links
    /// across accounts arrive as one contact rather than as a duplicate pair.
    /// Directory paging, duplicate ranking and recipient resolution all work
    /// from this snapshot, which keeps the ordering stable within a call.
    private func allContactRecords() async throws -> [ContactRecord] {
        try await runContactStore {
            let request = CNContactFetchRequest(keysToFetch: contactKeys)
            request.sortOrder = .userDefault
            var records: [ContactRecord] = []
            try self.contactStore.enumerateContacts(with: request) { contact, _ in
                records.append(ContactRecord(contact))
            }
            return records
        }
    }

    // MARK: - Destinations

    /// Every container this Mac exposes, with the system default flagged.
    ///
    /// Must be called on the contact-store queue.
    private func containerCandidates() throws -> [ContactContainerCandidate] {
        let defaultIdentifier = contactStore.defaultContainerIdentifier()
        return try contactStore.containers(matching: nil).map { container in
            ContactContainerCandidate(
                identifier: container.identifier,
                name: container.name,
                kind: Self.containerKind(for: container.type),
                isSystemDefault: container.identifier == defaultIdentifier
            )
        }
    }

    private static func containerKind(for type: CNContainerType) -> ContactContainerKind {
        switch type {
        case .local: return .local
        case .exchange: return .exchange
        case .cardDAV: return .cardDAV
        case .unassigned: return .unassigned
        @unknown default: return .unknown
        }
    }

    /// Where the store says a record actually lives, read back after a write.
    ///
    /// A failure here is reported as "unknown destination" rather than thrown:
    /// the contact has already been saved by that point, and losing the whole
    /// result because the follow-up read failed would be worse than saying the
    /// destination is unverified.
    private func container(
        ofContact identifier: String,
        among candidates: [ContactContainerCandidate]
    ) -> ContactContainerCandidate? {
        let predicate = CNContainer.predicateForContainerOfContact(withIdentifier: identifier)
        guard let found = try? contactStore.containers(matching: predicate).first else { return nil }
        return candidates.first { $0.identifier == found.identifier }
            ?? ContactContainerCandidate(
                identifier: found.identifier,
                name: found.name,
                kind: Self.containerKind(for: found.type)
            )
    }

    private func container(
        ofGroup identifier: String,
        among candidates: [ContactContainerCandidate]
    ) -> ContactContainerCandidate? {
        let predicate = CNContainer.predicateForContainerOfGroup(withIdentifier: identifier)
        guard let found = try? contactStore.containers(matching: predicate).first else { return nil }
        return candidates.first { $0.identifier == found.identifier }
            ?? ContactContainerCandidate(
                identifier: found.identifier,
                name: found.name,
                kind: Self.containerKind(for: found.type)
            )
    }

    private static func describe(_ container: ContactContainerCandidate) -> Value {
        .object([
            "identifier": .string(container.identifier),
            "name": .string(container.name),
            "kind": .string(container.kind.rawValue),
            "isICloud": .bool(container.isICloud),
            "syncsOffDevice": .bool(container.syncsOffDevice),
            "isSystemDefault": .bool(container.isSystemDefault),
        ])
    }

    private static func describe(_ report: ContactDestinationReport) -> Value {
        var described: [String: Value] = [
            "container": describe(report.container),
            "syncsOffDevice": .bool(report.syncsOffDevice),
            "isICloud": .bool(report.isICloud),
            "syncExpectation": .string(ContactDestinationReporting.syncExpectation(report)),
        ]
        if let warning = report.warning {
            described["warning"] = .string(warning)
        }
        return .object(described)
    }

    private static func describe(_ record: ContactRecord) -> Value {
        .object([
            "identifier": .string(record.identifier),
            "name": .string(record.displayName),
            "givenName": .string(record.givenName),
            "familyName": .string(record.familyName),
            "organizationName": .string(record.organizationName),
            "phoneNumbers": .array(record.phoneNumbers.map { .string($0) }),
            "emailAddresses": .array(record.emailAddresses.map { .string($0) }),
        ])
    }

    var tools: [Tool] {
        Tool(
            name: "contacts_me",
            description:
                "Get contact information about the user, including name, phone number, email, birthday, relations, address, online presence, and occupation. Always run this tool when the user asks a question that requires personal information about themselves.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Who Am I?",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let contact = try await self.runContactStore {
                try self.contactStore.unifiedMeContactWithKeys(toFetch: contactKeys)
            }
            return Person(contact)
        }

        Tool(
            name: "contacts_search",
            description:
                "Search contacts by name, phone number, and/or email",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name to search for"
                    ),
                    "phone": .string(
                        description: "Phone number to search for"
                    ),
                    "email": .string(
                        description: "Email address to search for"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Contacts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var predicates: [NSPredicate] = []

            if case let .string(name) = arguments["name"] {
                let normalizedName = name.trimmingCharacters(in: .whitespaces)
                if !normalizedName.isEmpty {
                    predicates.append(CNContact.predicateForContacts(matchingName: normalizedName))
                }
            }

            if case let .string(phone) = arguments["phone"] {
                let normalizedPhone = phone.trimmingCharacters(in: .whitespaces)
                if !normalizedPhone.isEmpty {
                    let phoneNumber = CNPhoneNumber(stringValue: normalizedPhone)
                    predicates.append(CNContact.predicateForContacts(matching: phoneNumber))
                }
            }

            if case let .string(email) = arguments["email"] {
                // Normalize email to lowercase
                let normalizedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
                if !normalizedEmail.isEmpty {
                    predicates.append(
                        CNContact.predicateForContacts(matchingEmailAddress: normalizedEmail)
                    )
                }
            }

            guard !predicates.isEmpty else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "At least one valid search parameter is required"
                    ]
                )
            }

            let contacts = try await self.runContactStore {
                var intersection: [CNContact]?
                for predicate in predicates {
                    let matches = try self.contactStore.unifiedContacts(
                        matching: predicate,
                        keysToFetch: contactKeys
                    )
                    if let existing = intersection {
                        let identifiers = Set(matches.map(\.identifier))
                        intersection = existing.filter { identifiers.contains($0.identifier) }
                    } else {
                        intersection = matches
                    }
                }
                return intersection ?? []
            }

            return Value.array(contacts.map { Self.describe($0) })
        }

        Tool(
            name: "contacts_update",
            description:
                "Update an existing contact's information. Only provide values for properties that need to be changed; omit any properties that should remain unchanged.",
            inputSchema: .object(
                properties: ([
                    "identifier": .string(
                        description: "Unique identifier of the contact to update"
                    )
                ] as OrderedDictionary).merging(
                    contactProperties,
                    uniquingKeysWith: { new, _ in new }
                ),
                required: ["identifier"]
            ),
            annotations: .init(
                title: "Update Contact",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(identifier) = arguments["identifier"], !identifier.isEmpty else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Valid contact identifier required"]
                )
            }

            // Fetch the mutable copy of the contact
            let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
            let contact =
                try await self.runContactStore {
                    try self.contactStore.unifiedContacts(matching: predicate, keysToFetch: contactKeys)
                }
                .first?
                .mutableCopy() as? CNMutableContact

            guard let updatedContact = contact else {
                throw NSError(
                    domain: "ContactsService",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Contact not found with identifier: \(identifier)"
                    ]
                )
            }

            // Update all properties
            try updatedContact.populate(from: arguments)

            // Create a save request
            let saveRequest = CNSaveRequest()
            saveRequest.update(updatedContact)

            // Save the changes
            try await self.runContactStore {
                try self.contactStore.execute(saveRequest)
            }

            return Person(updatedContact)
        }

        Tool(
            name: "contacts_containers",
            description:
                "List the Contacts containers (accounts) a contact can be created in, which one the system treats as default, and which look like iCloud. Pass contact to find out which container an existing contact lives in, which is how you tell a card that syncs from one that only exists on this Mac.",
            inputSchema: .object(
                properties: [
                    "contact": .string(
                        description:
                            "Optional contact identifier: also report which container that contact lives in"
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Contact Containers",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let contactIdentifier = arguments["contact"]?.stringValue
            return try await self.runContactStore {
                let candidates = try self.containerCandidates()
                var result: [String: Value] = [
                    "containers": .array(candidates.map(Self.describe))
                ]
                if let systemDefault = candidates.first(where: \.isSystemDefault) {
                    result["systemDefaultIdentifier"] = .string(systemDefault.identifier)
                }
                // The destination a write with no container argument would use,
                // reported up front so the caller never has to infer it.
                do {
                    let writeDefault = try ContactDestinationTarget.defaultDestination(in: candidates)
                    result["writeDefault"] = Self.describe(writeDefault)
                } catch {
                    result["writeDefaultUnavailable"] = .string(
                        error.localizedDescription
                    )
                }
                if let contactIdentifier, !contactIdentifier.isEmpty {
                    if let found = self.container(ofContact: contactIdentifier, among: candidates) {
                        result["contactContainer"] = Self.describe(found)
                        result["contactSyncExpectation"] = .string(
                            ContactDestinationReporting.syncExpectation(
                                ContactDestinationReporting.report(landed: found, requested: nil)
                            )
                        )
                    } else {
                        result["contactContainer"] = .null
                    }
                }
                return Value.object(result)
            }
        }

        Tool(
            name: "contacts_create",
            description:
                "Create a new contact with the specified information. Without container the contact goes to iCloud, and creation fails rather than falling back to an on-this-Mac account when no iCloud container exists. The result reports the container the contact actually landed in.",
            inputSchema: .object(
                properties: contactProperties.merging([
                    "container": .string(
                        description:
                            "Container identifier or name from contacts_containers. Omit to use iCloud."
                    )
                ]) { current, _ in current },
                required: ["givenName"]
            ),
            annotations: .init(
                title: "Create Contact",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            // Create and populate a new contact
            let newContact = CNMutableContact()
            try newContact.populate(from: arguments)

            // Validate that given name is provided and not empty
            if newContact.givenName.isEmpty {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Given name is required"]
                )
            }

            let requestedContainer = arguments["container"]?.stringValue
            let report: ContactDestinationReport = try await self.runContactStore {
                let candidates = try self.containerCandidates()
                // Resolve before saving: an unknown or ambiguous destination
                // must fail without writing anything.
                let target = try ContactDestinationTarget.resolve(
                    requested: requestedContainer,
                    in: candidates
                )
                let saveRequest = CNSaveRequest()
                saveRequest.add(newContact, toContainerWithIdentifier: target.identifier)
                try self.contactStore.execute(saveRequest)
                let landed = self.container(
                    ofContact: newContact.identifier,
                    among: candidates
                )
                return ContactDestinationReporting.report(landed: landed, requested: target)
            }

            return Value.object([
                "contact": try Value(Person(newContact)),
                "destination": Self.describe(report),
            ])
        }

        Tool(
            name: "contacts_get",
            description: "Fetch one contact by its unique identifier",
            inputSchema: .object(
                properties: [
                    "identifier": .string(description: "Unique identifier of the contact")
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Contact",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let identifier = arguments["identifier"]?.stringValue else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing identifier"]
                )
            }
            let contact = try await self.runContactStore {
                try self.contactStore.unifiedContact(
                    withIdentifier: identifier,
                    keysToFetch: contactKeys
                )
            }
            return Self.describe(contact)
        }

        Tool(
            name: "contacts_delete",
            description:
                "Delete a contact. This cannot be undone, so confirm with the user before calling it.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(description: "Unique identifier of the contact to delete")
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Contact",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let identifier = arguments["identifier"]?.stringValue else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing identifier"]
                )
            }
            let name: String = try await self.runContactStore {
                let existing = try self.contactStore.unifiedContact(
                    withIdentifier: identifier,
                    keysToFetch: contactKeys
                )
                // `delete` needs a mutable copy; the fetched contact is
                // immutable and passing it through throws at execute time.
                guard let mutable = existing.mutableCopy() as? CNMutableContact else {
                    throw NSError(
                        domain: "ContactsService",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not prepare the contact for deletion"]
                    )
                }
                let request = CNSaveRequest()
                request.delete(mutable)
                try self.contactStore.execute(request)
                return [existing.givenName, existing.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(identifier),
                "name": .string(name),
            ])
        }

        Tool(
            name: "contacts_groups",
            description: "List contact groups",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "List Contact Groups",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let groups = try await self.runContactStore {
                try self.contactStore.groups(matching: nil)
            }
            let described: [Value] = groups.map { group in
                .object([
                    "identifier": .string(group.identifier),
                    "name": .string(group.name),
                ])
            }
            return Value.object(["groups": .array(described)])
        }

        Tool(
            name: "contacts_group_members",
            description: "List the contacts in a group. Get the group identifier from contacts_groups.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(description: "Group identifier")
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Group Members",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let identifier = arguments["identifier"]?.stringValue else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing identifier"]
                )
            }
            let members = try await self.runContactStore {
                try self.contactStore.unifiedContacts(
                    matching: CNContact.predicateForContactsInGroup(withIdentifier: identifier),
                    keysToFetch: contactKeys
                )
            }
            return members.compactMap { Person($0) }
        }

        Tool(
            name: "contacts_create_group",
            description:
                "Create a contact group. Groups belong to one container, and a group cannot hold contacts from another container, so the same destination rules as contacts_create apply: without container the group goes to iCloud.",
            inputSchema: .object(
                properties: [
                    "name": .string(description: "Name for the new group"),
                    "container": .string(
                        description:
                            "Container identifier or name from contacts_containers. Omit to use iCloud."
                    ),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Contact Group",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "A group name is required"]
                )
            }
            let requestedContainer = arguments["container"]?.stringValue
            let created: (identifier: String, report: ContactDestinationReport) =
                try await self.runContactStore {
                    let candidates = try self.containerCandidates()
                    let target = try ContactDestinationTarget.resolve(
                        requested: requestedContainer,
                        in: candidates
                    )
                    let group = CNMutableGroup()
                    group.name = name
                    let request = CNSaveRequest()
                    request.add(group, toContainerWithIdentifier: target.identifier)
                    try self.contactStore.execute(request)
                    let landed = self.container(ofGroup: group.identifier, among: candidates)
                    return (
                        group.identifier,
                        ContactDestinationReporting.report(landed: landed, requested: target)
                    )
                }
            return Value.object([
                "identifier": .string(created.identifier),
                "name": .string(name),
                "destination": Self.describe(created.report),
            ])
        }

        Tool(
            name: "contacts_rename_group",
            description:
                "Rename a contact group. The group keeps its identifier and its members; only the name changes.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(description: "Group identifier from contacts_groups"),
                    "name": .string(description: "New name for the group"),
                ],
                required: ["identifier", "name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Rename Contact Group",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let identifier = try Self.requiredIdentifier("identifier", from: arguments)
            let name = try ContactGroupName.normalize(arguments["name"]?.stringValue)

            let previousName: String = try await self.runContactStore {
                let group = try self.resolveGroup(identifier)
                guard let mutable = group.mutableCopy() as? CNMutableGroup else {
                    throw NSError(
                        domain: "ContactsService",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Could not prepare the group for renaming"
                        ]
                    )
                }
                let previous = group.name
                mutable.name = name
                let request = CNSaveRequest()
                request.update(mutable)
                try self.contactStore.execute(request)
                return previous
            }

            // Everything reported here was read before the save. Nothing is
            // read back afterwards, so a follow-up read cannot fail a rename
            // that already happened and send the caller round again.
            return Value.object([
                "renamed": .bool(true),
                "identifier": .string(identifier),
                "name": .string(name),
                "previousName": .string(previousName),
            ])
        }

        Tool(
            name: "contacts_delete_group",
            description:
                "Delete a contact group. The contacts in it are not deleted: they stay in the address book "
                + "and lose only their membership of this group. Deleting a group cannot be undone from here, "
                + "so confirm with the user first.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(description: "Group identifier from contacts_groups")
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Contact Group",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let identifier = try Self.requiredIdentifier("identifier", from: arguments)

            // The membership count is read before the delete, both because it
            // is unavailable afterwards and because a read that fails here
            // fails before anything has been changed.
            let deleted: (name: String, memberCount: Int) = try await self.runContactStore {
                let group = try self.resolveGroup(identifier)
                let members = try self.contactStore.unifiedContacts(
                    matching: CNContact.predicateForContactsInGroup(withIdentifier: identifier),
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                )
                guard let mutable = group.mutableCopy() as? CNMutableGroup else {
                    throw NSError(
                        domain: "ContactsService",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Could not prepare the group for deletion"
                        ]
                    )
                }
                let request = CNSaveRequest()
                request.delete(mutable)
                try self.contactStore.execute(request)
                return (group.name, members.count)
            }

            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(identifier),
                "name": .string(deleted.name),
                "formerMemberCount": .int(deleted.memberCount),
                "contactsDeleted": .bool(false),
                "note": .string(
                    "The \(deleted.memberCount) contact(s) that were in this group still exist; "
                        + "only the group was removed."
                ),
            ])
        }

        Tool(
            name: "contacts_group_add",
            description: "Add a contact to a group",
            inputSchema: .object(
                properties: [
                    "group": .string(description: "Group identifier from contacts_groups"),
                    "contact": .string(description: "Contact identifier"),
                ],
                required: ["group", "contact"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Add Contact to Group",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let groupID = try Self.requiredIdentifier("group", from: arguments)
            let contactID = try Self.requiredIdentifier("contact", from: arguments)
            try await self.runContactStore {
                let (group, contact) = try self.resolveGroupAndContact(groupID, contactID)
                let request = CNSaveRequest()
                request.addMember(contact, to: group)
                try self.contactStore.execute(request)
            }
            return Value.object(["added": .bool(true), "group": .string(groupID)])
        }

        Tool(
            name: "contacts_group_remove",
            description: "Remove a contact from a group. The contact itself is not deleted.",
            inputSchema: .object(
                properties: [
                    "group": .string(description: "Group identifier from contacts_groups"),
                    "contact": .string(description: "Contact identifier"),
                ],
                required: ["group", "contact"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Remove Contact from Group",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let groupID = try Self.requiredIdentifier("group", from: arguments)
            let contactID = try Self.requiredIdentifier("contact", from: arguments)
            try await self.runContactStore {
                let (group, contact) = try self.resolveGroupAndContact(groupID, contactID)
                let request = CNSaveRequest()
                request.removeMember(contact, from: group)
                try self.contactStore.execute(request)
            }
            return Value.object(["removed": .bool(true), "group": .string(groupID)])
        }

        Tool(
            name: "contacts_photo",
            description:
                "Get a contact's photo as a base64-encoded PNG or JPEG. Returns nothing when the contact has no photo.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(description: "Unique identifier of the contact"),
                    "thumbnail": .boolean(
                        description: "Return the small thumbnail instead of the full-size image",
                        default: .bool(true)
                    ),
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Contact Photo",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let identifier = arguments["identifier"]?.stringValue else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing identifier"]
                )
            }
            let wantsThumbnail = arguments["thumbnail"]?.boolValue ?? true
            // Image data is a separate key set: fetching it for every contact
            // search would be wasteful, so it is only requested here.
            let imageKeys =
                [
                    CNContactImageDataKey,
                    CNContactThumbnailImageDataKey,
                    CNContactImageDataAvailableKey,
                ] as [CNKeyDescriptor]

            let data: Data? = try await self.runContactStore {
                let contact = try self.contactStore.unifiedContact(
                    withIdentifier: identifier,
                    keysToFetch: imageKeys
                )
                guard contact.imageDataAvailable else { return nil }
                return wantsThumbnail ? contact.thumbnailImageData : contact.imageData
            }

            guard let data else {
                return Value.object([
                    "identifier": .string(identifier),
                    "hasPhoto": .bool(false),
                ])
            }
            return Value.object([
                "identifier": .string(identifier),
                "hasPhoto": .bool(true),
                "sizeBytes": .int(data.count),
                "base64": .string(data.base64EncodedString()),
            ])
        }

        Tool(
            name: "contacts_directory",
            description:
                "Page through the address book in a stable order. Use this to browse or count contacts; use contacts_search when you already know a name, phone number or email.",
            inputSchema: .object(
                properties: [
                    "prefix": .string(
                        description:
                            "Only include contacts whose family, given, nickname or organization name starts with this text"
                    ),
                    "offset": .integer(
                        description: "How many contacts to skip, for paging through the directory",
                        default: .int(0),
                        minimum: 0
                    ),
                    "limit": .integer(
                        description: "Maximum contacts to return in one page",
                        default: .int(ContactDirectory.defaultLimit),
                        minimum: 1,
                        maximum: ContactDirectory.maximumLimit
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Browse Contacts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let records = try await self.allContactRecords()
            let filtered: [ContactRecord]
            if let prefix = arguments["prefix"]?.stringValue, !prefix.isEmpty {
                filtered = records.filter { ContactDirectory.matchesPrefix($0, prefix: prefix) }
            } else {
                filtered = records
            }
            let page = ContactDirectory.page(
                ContactDirectory.sorted(filtered),
                offset: ContactDirectory.clampedOffset(arguments["offset"]?.intValue),
                limit: ContactDirectory.clampedLimit(arguments["limit"]?.intValue)
            )
            var result: [String: Value] = [
                "total": .int(page.total),
                "offset": .int(page.offset),
                "limit": .int(page.limit),
                "hasMore": .bool(page.hasMore),
                "contacts": .array(page.records.map(Self.describe)),
            ]
            if let nextOffset = page.nextOffset {
                result["nextOffset"] = .int(nextOffset)
            }
            return Value.object(result)
        }

        Tool(
            name: "contacts_duplicates",
            description:
                "Suggest contacts that may be duplicates of each other, ranked strongest first, with the evidence behind each pair. Read-only: this never merges contacts, and merging is not available as a tool. Report the pairs to the user and let them merge in the Contacts app.",
            inputSchema: .object(
                properties: [
                    "limit": .integer(
                        description: "Maximum suggested pairs to return",
                        default: .int(20),
                        minimum: 1,
                        maximum: 200
                    ),
                    "minimum_score": .number(
                        description:
                            "Drop pairs scoring below this. 0.8 and above is a strong match; 0.45 is the weakest reported.",
                        default: .double(ContactDuplicates.minimumScore),
                        minimum: 0,
                        maximum: 1
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Suggest Duplicate Contacts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let records = try await self.allContactRecords()
            let threshold = arguments["minimum_score"]?.doubleCoerced ?? ContactDuplicates.minimumScore
            let limit = min(max(arguments["limit"]?.intValue ?? 20, 1), 200)
            let suggestions = ContactDuplicates.suggestions(
                for: records,
                minimumScore: min(max(threshold, 0), 1)
            )
            let described = suggestions.prefix(limit).map { suggestion in
                Value.object([
                    "identifiers": .array(suggestion.identifiers.map { .string($0) }),
                    "names": .array(suggestion.names.map { .string($0) }),
                    "score": .double(suggestion.score),
                    "confidence": .string(suggestion.confidence),
                    "reasons": .array(suggestion.reasons.map { .string($0) }),
                    "cautions": .array(suggestion.cautions.map { .string($0) }),
                ])
            }
            return Value.object([
                "scanned": .int(records.count),
                "total": .int(suggestions.count),
                "suggestions": .array(Array(described)),
                "guidance": .string(
                    "These are suggestions only. Merging contacts cannot be undone, so review them with the user "
                        + "and let them merge in the Contacts app."
                ),
            ])
        }

        Tool(
            name: "contacts_resolve_recipient",
            description:
                "Find who a name, email or phone number refers to, as ranked candidates. Returns whether the match is confident or ambiguous. When it is not confident, show the candidates to the user and ask, rather than sending anything to the top result.",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "A name, email address or phone number"
                    ),
                    "channel": .string(
                        description: "Which kind of address the caller intends to use",
                        default: .string(RecipientChannel.any.rawValue),
                        enum: RecipientChannel.allCases.map { .string($0.rawValue) }
                    ),
                    "limit": .integer(
                        description: "Maximum candidates to return",
                        default: .int(ContactRecipients.maximumCandidates),
                        minimum: 1,
                        maximum: 50
                    ),
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Resolve Recipient",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let query = arguments["query"]?.stringValue else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing required argument: query"]
                )
            }
            let channel =
                arguments["channel"]?.stringValue.flatMap(RecipientChannel.init(rawValue:)) ?? .any
            let records = try await self.allContactRecords()
            let resolution = ContactRecipients.resolve(
                query: query,
                in: records,
                channel: channel,
                limit: min(max(arguments["limit"]?.intValue ?? ContactRecipients.maximumCandidates, 1), 50)
            )
            let candidates = resolution.candidates.map { candidate in
                Value.object([
                    "identifier": .string(candidate.identifier),
                    "name": .string(candidate.name),
                    "score": .double(candidate.score),
                    "matchType": .string(candidate.matchType),
                    "emailAddresses": .array(candidate.emailAddresses.map { .string($0) }),
                    "phoneNumbers": .array(candidate.phoneNumbers.map { .string($0) }),
                ])
            }
            return Value.object([
                "query": .string(resolution.query),
                "channel": .string(resolution.channel),
                "isConfident": .bool(resolution.isConfident),
                "isAmbiguous": .bool(resolution.isAmbiguous),
                "needsAddressChoice": .bool(resolution.needsAddressChoice),
                "guidance": .string(resolution.guidance),
                "candidates": .array(candidates),
            ])
        }

        Tool(
            name: "contacts_changes",
            description:
                "What has changed in Contacts since a previous call. Call it once with no token to "
                + "get a starting cursor, then pass that token back later to receive only the "
                + "contacts and groups added, updated or deleted since — including group membership "
                + "changes. This is the cheap way to keep an external copy current: it does not "
                + "re-read the address book. A token that macOS has aged out is reported as "
                + "resyncRequired, meaning the caller should read everything again.",
            inputSchema: .object(
                properties: [
                    "token": .string(
                        description:
                            "A token from an earlier contacts_changes call. Omit to get a starting "
                            + "cursor without any history."
                    ),
                    "limit": .integer(
                        description: "Maximum change events to return. Defaults to 200.",
                        default: .int(200)
                    ),
                    "includeGroups": .boolean(
                        description: "Include group and group-membership changes. Defaults to true.",
                        default: .bool(true)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Contacts Changes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            let limit = min(max(arguments["limit"]?.intValue ?? 200, 1), 1000)
            let includeGroups = arguments["includeGroups"]?.boolValue ?? true

            guard let tokenString = arguments["token"]?.stringValue, !tokenString.isEmpty else {
                // No token: hand back a cursor and nothing else. Replaying the
                // whole history of an address book on a first call would be a
                // large, slow answer to a question the caller did not ask.
                let current = try await self.runContactStore { self.contactStore.currentHistoryToken }
                guard let current else {
                    throw NSError(
                        domain: "ContactsService",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Contacts did not provide a change token on this system, so "
                                + "incremental change tracking is unavailable."
                        ]
                    )
                }
                return Value.object([
                    "token": .string(current.base64EncodedString()),
                    "changes": .array([]),
                    "count": .int(0),
                    "hasMore": .bool(false),
                    "resyncRequired": .bool(false),
                    "note": .string(
                        "Starting cursor. Pass this token back to see what changed after now."
                    ),
                ])
            }

            guard let startingToken = Data(base64Encoded: tokenString) else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "token is not a token from contacts_changes; pass the value returned "
                            + "by an earlier call, unchanged."
                    ]
                )
            }

            return try await self.runContactStore {
                let request = CNChangeHistoryFetchRequest()
                request.startingToken = startingToken
                request.includeGroupChanges = includeGroups
                request.shouldUnifyResults = false
                request.additionalContactKeyDescriptors = contactKeys

                // Apple marks this method NS_SWIFT_UNAVAILABLE, so it is not
                // callable as written even though it is public, supported API
                // that has shipped since macOS 10.15. Binding the selector
                // through an @objc shim reaches the same implementation the
                // Objective-C caller gets; nothing private is involved.
                let store = unsafeBitCast(self.contactStore, to: CNChangeHistoryCapable.self)
                let fetched = try store.enumeratorForChangeHistory(request)
                let result = unsafeBitCast(fetched, to: CNChangeHistoryFetchResult.self)
                guard let enumerator = result.value as? NSEnumerator else {
                    throw NSError(
                        domain: "ContactsService",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Contacts returned change history in a shape this version of Apple "
                                + "Core does not recognize, so incremental change tracking is "
                                + "unavailable on this system."
                        ]
                    )
                }
                let collector = ContactChangeCollector(limit: limit)
                while let event = enumerator.nextObject() as? CNChangeHistoryEvent {
                    if collector.changes.count >= limit {
                        collector.hasMore = true
                        break
                    }
                    event.accept(collector)
                }

                var payload: [String: Value] = [
                    // The token advances to the end of what was *available*,
                    // not the end of what was returned. When a page was
                    // truncated the old token is kept, so the next call
                    // resumes where this one stopped rather than skipping the
                    // events it did not show.
                    "token": .string(
                        collector.hasMore
                            ? tokenString
                            : (result.currentHistoryToken?.base64EncodedString() ?? tokenString)
                    ),
                    "changes": .array(collector.changes),
                    "count": .int(collector.changes.count),
                    "hasMore": .bool(collector.hasMore),
                    "resyncRequired": .bool(collector.resyncRequired),
                ]
                if collector.resyncRequired {
                    payload["note"] = .string(
                        "Contacts discarded the history this token pointed at. Read the address "
                            + "book again with contacts_directory and start a fresh cursor."
                    )
                }
                return .object(payload)
            }
        }
    }
}

/// `CNContactStore.enumeratorForChangeHistoryFetchRequest:error:` and
/// `CNFetchResult`, bound by selector.
///
/// Both are public, documented Contacts API available since macOS 10.15, but
/// Apple annotates the method `NS_SWIFT_UNAVAILABLE` and so Swift refuses to
/// call it. These protocols name the same selectors the Objective-C caller
/// uses. Swift maps the trailing `NSError **` onto `throws`.
@objc private protocol CNChangeHistoryCapable {
    @objc(enumeratorForChangeHistoryFetchRequest:error:)
    func enumeratorForChangeHistory(_ request: CNChangeHistoryFetchRequest) throws -> AnyObject
}

@objc private protocol CNChangeHistoryFetchResult {
    @objc(value) var value: AnyObject? { get }
    @objc(currentHistoryToken) var currentHistoryToken: Data? { get }
}

/// Turns the change-history visitor callbacks into plain change entries.
///
/// `CNChangeHistoryEvent` dispatches through a visitor protocol rather than
/// exposing a type discriminator, so collecting the events means implementing
/// all eleven callbacks. A class, because the protocol is `@objc`.
private final class ContactChangeCollector: NSObject, CNChangeHistoryEventVisitor {
    let limit: Int
    var changes: [Value] = []
    var hasMore = false
    /// Set when macOS says the token is too old to resume from.
    var resyncRequired = false

    init(limit: Int) {
        self.limit = limit
    }

    private func record(_ kind: String, _ fields: [String: Value] = [:]) {
        guard changes.count < limit else {
            hasMore = true
            return
        }
        var entry = fields
        entry["change"] = .string(kind)
        changes.append(.object(entry))
    }

    func visit(_ event: CNChangeHistoryDropEverythingEvent) {
        // Not a change to report: the history itself is gone.
        resyncRequired = true
    }

    func visit(_ event: CNChangeHistoryAddContactEvent) {
        var fields: [String: Value] = ["contact": ContactsService.describe(event.contact)]
        if let container = event.containerIdentifier {
            fields["container"] = .string(container)
        }
        record("contact_added", fields)
    }

    func visit(_ event: CNChangeHistoryUpdateContactEvent) {
        record("contact_updated", ["contact": ContactsService.describe(event.contact)])
    }

    func visit(_ event: CNChangeHistoryDeleteContactEvent) {
        // A deleted contact is only an identifier; the record is gone.
        record("contact_deleted", ["identifier": .string(event.contactIdentifier)])
    }

    func visit(_ event: CNChangeHistoryAddGroupEvent) {
        var fields: [String: Value] = [
            "group": .object([
                "identifier": .string(event.group.identifier),
                "name": .string(event.group.name),
            ])
        ]
        let container = event.containerIdentifier
        if !container.isEmpty { fields["container"] = .string(container) }
        record("group_added", fields)
    }

    func visit(_ event: CNChangeHistoryUpdateGroupEvent) {
        record(
            "group_updated",
            [
                "group": .object([
                    "identifier": .string(event.group.identifier),
                    "name": .string(event.group.name),
                ])
            ]
        )
    }

    func visit(_ event: CNChangeHistoryDeleteGroupEvent) {
        record("group_deleted", ["identifier": .string(event.groupIdentifier)])
    }

    func visit(_ event: CNChangeHistoryAddMemberToGroupEvent) {
        record("group_member_added", Self.membership(member: event.member, group: event.group))
    }

    func visit(_ event: CNChangeHistoryRemoveMemberFromGroupEvent) {
        record("group_member_removed", Self.membership(member: event.member, group: event.group))
    }

    func visit(_ event: CNChangeHistoryAddSubgroupToGroupEvent) {
        record(
            "subgroup_added",
            [
                "subgroup": .string(event.subgroup.identifier),
                "group": .string(event.group.identifier),
            ]
        )
    }

    func visit(_ event: CNChangeHistoryRemoveSubgroupFromGroupEvent) {
        record(
            "subgroup_removed",
            [
                "subgroup": .string(event.subgroup.identifier),
                "group": .string(event.group.identifier),
            ]
        )
    }

    private static func membership(member: CNContact, group: CNGroup) -> [String: Value] {
        [
            "contact": .string(member.identifier),
            "group": .object([
                "identifier": .string(group.identifier),
                "name": .string(group.name),
            ]),
        ]
    }
}

extension ContactsService {
    /// One contact, with the fields the schema.org `Person` type cannot carry.
    ///
    /// Two things were wrong with returning `Person(contact)` alone.
    ///
    /// First, `Person.init?` returns nil for any contact whose `contactType`
    /// is `.organization`. Every company in the address book therefore
    /// vanished from `contacts_search` (a `compactMap` swallowed it) and
    /// `contacts_get` answered nil for a contact that plainly exists.
    ///
    /// Second, `Person` flattens phone numbers and email addresses to bare
    /// strings. A caller reading a contact could see three numbers and not
    /// know which was the mobile — and then could not write them back, because
    /// the update path is label-keyed.
    ///
    /// This returns the whole record. `Person` is still emitted alongside for
    /// callers that already read it, so nothing that worked before changes.
    /// A display name that cannot abort the process.
    ///
    /// `CNContactFormatter` is the right answer for locale-correct name order,
    /// but it raises `CNPropertyNotFetchedException` rather than returning nil
    /// when a required key is missing, and an Objective-C exception crossing
    /// Swift terminates the app. So the keys are checked first, and a contact
    /// that somehow arrives without them is named from what it does carry
    /// instead of taking the connector down.
    static func displayName(of contact: CNContact) -> String {
        let required = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        if contact.areKeysAvailable([required]),
            let formatted = CNContactFormatter.string(from: contact, style: .fullName),
            !formatted.isEmpty
        {
            return formatted
        }
        // Reading any unfetched property raises the same exception, so the
        // fallback has to ask before it reads rather than assume the name keys
        // are there. Two fetch paths in this file deliberately ask for the
        // identifier alone.
        func available(_ key: String) -> Bool {
            contact.areKeysAvailable([key as CNKeyDescriptor])
        }
        let parts = [
            available(CNContactGivenNameKey) ? contact.givenName : "",
            available(CNContactMiddleNameKey) ? contact.middleName : "",
            available(CNContactFamilyNameKey) ? contact.familyName : "",
        ].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if available(CNContactOrganizationNameKey), !contact.organizationName.isEmpty {
            return contact.organizationName
        }
        if available(CNContactNicknameKey), !contact.nickname.isEmpty {
            return contact.nickname
        }
        return ""
    }

    static func detail(of contact: CNContact) -> [String: Value] {
        var detail: [String: Value] = [
            "identifier": .string(contact.identifier),
            "contactType": .string(contact.contactType == .organization ? "organization" : "person"),
            "displayName": .string(displayName(of: contact)),
            "hasImage": .bool(contact.imageDataAvailable),
        ]

        func put(_ key: String, _ value: String) {
            if !value.isEmpty { detail[key] = .string(value) }
        }
        put("namePrefix", contact.namePrefix)
        put("givenName", contact.givenName)
        put("middleName", contact.middleName)
        put("familyName", contact.familyName)
        put("nameSuffix", contact.nameSuffix)
        put("previousFamilyName", contact.previousFamilyName)
        put("nickname", contact.nickname)
        put("organizationName", contact.organizationName)
        put("departmentName", contact.departmentName)
        put("jobTitle", contact.jobTitle)
        put("phoneticGivenName", contact.phoneticGivenName)
        put("phoneticMiddleName", contact.phoneticMiddleName)
        put("phoneticFamilyName", contact.phoneticFamilyName)
        put("phoneticOrganizationName", contact.phoneticOrganizationName)

        if let birthday = contact.birthday, let formatted = Self.describe(birthday) {
            detail["birthday"] = .string(formatted)
        }
        if let other = contact.nonGregorianBirthday, let formatted = Self.describe(other) {
            detail["nonGregorianBirthday"] = .string(formatted)
        }
        if !contact.dates.isEmpty {
            detail["dates"] = .array(
                contact.dates.compactMap { labelled in
                    guard let formatted = Self.describe(labelled.value as DateComponents) else {
                        return nil
                    }
                    return Value.object([
                        "label": .string(Self.readable(labelled.label)),
                        "date": .string(formatted),
                    ])
                }
            )
        }

        // Labelled values keep their label and their stable per-value
        // identifier, which is the handle for editing one of several.
        func labelled<T>(_ values: [CNLabeledValue<T>], _ describe: (T) -> Value?) -> Value {
            .array(
                values.compactMap { entry in
                    guard let described = describe(entry.value) else { return nil }
                    return Value.object([
                        "label": .string(Self.readable(entry.label)),
                        "value": described,
                        "identifier": .string(entry.identifier),
                    ])
                }
            )
        }
        if !contact.phoneNumbers.isEmpty {
            detail["phoneNumbers"] = labelled(contact.phoneNumbers) { .string($0.stringValue) }
        }
        if !contact.emailAddresses.isEmpty {
            detail["emailAddresses"] = labelled(contact.emailAddresses) { .string($0 as String) }
        }
        if !contact.urlAddresses.isEmpty {
            detail["urlAddresses"] = labelled(contact.urlAddresses) { .string($0 as String) }
        }
        if !contact.contactRelations.isEmpty {
            detail["relations"] = labelled(contact.contactRelations) { .string($0.name) }
        }
        if !contact.socialProfiles.isEmpty {
            detail["socialProfiles"] = labelled(contact.socialProfiles) { profile in
                var entry: [String: Value] = [:]
                if !profile.service.isEmpty { entry["service"] = .string(profile.service) }
                if !profile.username.isEmpty { entry["username"] = .string(profile.username) }
                if !profile.urlString.isEmpty { entry["url"] = .string(profile.urlString) }
                return entry.isEmpty ? nil : .object(entry)
            }
        }
        if !contact.instantMessageAddresses.isEmpty {
            detail["instantMessageAddresses"] = labelled(contact.instantMessageAddresses) { address in
                .object([
                    "service": .string(address.service),
                    "username": .string(address.username),
                ])
            }
        }
        if !contact.postalAddresses.isEmpty {
            detail["postalAddresses"] = labelled(contact.postalAddresses) { address in
                var entry: [String: Value] = [:]
                if !address.street.isEmpty { entry["street"] = .string(address.street) }
                if !address.city.isEmpty { entry["city"] = .string(address.city) }
                if !address.state.isEmpty { entry["state"] = .string(address.state) }
                if !address.postalCode.isEmpty { entry["postalCode"] = .string(address.postalCode) }
                if !address.country.isEmpty { entry["country"] = .string(address.country) }
                if !address.isoCountryCode.isEmpty {
                    entry["isoCountryCode"] = .string(address.isoCountryCode)
                }
                entry["formatted"] = .string(
                    CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
                )
                return .object(entry)
            }
        }
        return detail
    }

    /// A contact date has no year when the person did not give one, which is
    /// ordinary for a birthday. Emitting "0000-05-14" would be a lie about the
    /// year, so a yearless date is written without one.
    static func describe(_ components: DateComponents) -> String? {
        guard let month = components.month, let day = components.day else { return nil }
        if let year = components.year, year > 0 {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "--%02d-%02d", month, day)
    }

    /// Contacts stores labels as "_$!<Mobile>!$_"; a caller wants "Mobile".
    static func readable(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "other" }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }

    /// The whole record: the schema.org shape callers already read, plus every
    /// field it has no room for. An organization contact has no `person` half
    /// and says so, rather than disappearing.
    static func describe(_ contact: CNContact) -> Value {
        var entry = detail(of: contact)
        if let person = Person(contact), let encoded = try? Value(person) {
            entry["person"] = encoded
        }
        return .object(entry)
    }
}

extension ContactRecord {
    /// Unified contacts only: `linkedIdentifiers` carries the contact's own
    /// identifier because CNContact does not expose the records it was
    /// unified from, and a unified fetch has already collapsed them.
    init(_ contact: CNContact) {
        self.init(
            identifier: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            nickname: contact.nickname,
            organizationName: contact.organizationName,
            phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
            emailAddresses: contact.emailAddresses.map { $0.value as String },
            linkedIdentifiers: [contact.identifier]
        )
    }
}
