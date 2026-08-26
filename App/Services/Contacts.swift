import Contacts
import Foundation
import JSONSchema
import OSLog
import Ontology
import OrderedCollections

private let log = Logger.service("contacts")

private let contactKeys =
    [
        CNContactTypeKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactBirthdayKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactInstantMessageAddressesKey,
        CNContactSocialProfilesKey,
        CNContactUrlAddressesKey,
        CNContactPostalAddressesKey,
        CNContactRelationsKey,
    ] as [CNKeyDescriptor]

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
                let phoneNumber = CNPhoneNumber(stringValue: phone)
                predicates.append(CNContact.predicateForContacts(matching: phoneNumber))
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

            // Combine predicates with AND if multiple criteria are provided
            let finalPredicate =
                predicates.count == 1
                ? predicates[0]
                : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            let contacts = try await self.runContactStore {
                try self.contactStore.unifiedContacts(
                    matching: finalPredicate,
                    keysToFetch: contactKeys
                )
            }

            return contacts.compactMap { Person($0) }
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
            name: "contacts_create",
            description:
                "Create a new contact with the specified information.",
            inputSchema: .object(
                properties: contactProperties,
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

            // Create a save request
            let saveRequest = CNSaveRequest()
            saveRequest.add(newContact, toContainerWithIdentifier: nil)

            // Execute the save request
            try await self.runContactStore {
                try self.contactStore.execute(saveRequest)
            }
            return Person(newContact)
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
            return Person(contact)
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
            description: "Create a contact group",
            inputSchema: .object(
                properties: [
                    "name": .string(description: "Name for the new group")
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
            let identifier: String = try await self.runContactStore {
                let group = CNMutableGroup()
                group.name = name
                let request = CNSaveRequest()
                request.add(group, toContainerWithIdentifier: nil)
                try self.contactStore.execute(request)
                return group.identifier
            }
            return Value.object([
                "identifier": .string(identifier),
                "name": .string(name),
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
    }
}
