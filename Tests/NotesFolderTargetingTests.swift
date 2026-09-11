import Foundation
import JavaScriptCore
import Testing

@Suite("Notes folder targeting")
struct NotesFolderTargetingTests {

    @Test("No folder, account or id means no resolution and no Apple Event")
    func nothingToResolve() {
        #expect(!NotesFolderTargeting.needsResolution(folder: "", account: "", folderId: ""))
    }

    @Test(
        "Any one of the three selectors triggers resolution",
        arguments: [("Recipes", "", ""), ("", "iCloud", ""), ("", "", "folder-7")]
    )
    func somethingToResolve(selectors: (String, String, String)) {
        #expect(
            NotesFolderTargeting.needsResolution(
                folder: selectors.0,
                account: selectors.1,
                folderId: selectors.2
            )
        )
    }

    // MARK: - The real script

    /// Two accounts, as on any Mac with an On My Mac store beside iCloud.
    /// "Notes" and "Recipes" exist in both, which is exactly the collision
    /// that used to resolve to whichever account the scripting interface
    /// happened to reach first.
    private static let twoAccounts = """
        [
            { name: 'iCloud', folders: [
                { id: 'icloud-notes', name: 'Notes' },
                { id: 'icloud-recipes', name: 'Recipes' },
                { id: 'icloud-work', name: 'Work' }
            ] },
            { name: 'On My Mac', folders: [
                { id: 'local-notes', name: 'Notes' },
                { id: 'local-recipes', name: 'Recipes' }
            ] }
        ]
        """

    @Test("A name in two accounts is refused, and the refusal names both")
    func ambiguousName() throws {
        let context = try fixture()
        context.resolve(["Recipes", "", ""])
        let failure = context.failure()
        #expect(failure.contains(NotesFolderTargeting.ambiguousFolderPrefix))
        #expect(failure.contains("iCloud"))
        #expect(failure.contains("On My Mac"))
        #expect(failure.contains("folder_id"))
    }

    @Test(
        "An account narrows an otherwise ambiguous name",
        arguments: [("iCloud", "icloud-recipes"), ("On My Mac", "local-recipes")]
    )
    func accountNarrows(expected: (account: String, id: String)) throws {
        let context = try fixture()
        let target = try context.target(["Recipes", expected.account, ""])
        #expect(target.scope == "folder")
        #expect(target.isFolderScoped)
        #expect(target.id == expected.id)
        #expect(target.name == "Recipes")
        #expect(target.accountName == expected.account)
    }

    @Test("A folder id is exact, and needs no account")
    func idResolves() throws {
        let context = try fixture()
        let target = try context.target(["", "", "local-notes"])
        #expect(target.id == "local-notes")
        #expect(target.name == "Notes")
        #expect(target.accountName == "On My Mac")
    }

    @Test("A folder id wins over a folder name that disagrees with it")
    func idBeatsName() throws {
        let context = try fixture()
        let target = try context.target(["Work", "", "local-recipes"])
        #expect(target.id == "local-recipes")
        #expect(target.name == "Recipes")
    }

    @Test("A name unique to one account resolves without an account")
    func uniqueName() throws {
        let context = try fixture()
        let target = try context.target(["Work", "", ""])
        #expect(target.id == "icloud-work")
        #expect(target.accountName == "iCloud")
    }

    @Test("An account alone scopes to the whole account")
    func accountOnly() throws {
        let context = try fixture()
        let target = try context.target(["", "On My Mac", ""])
        #expect(target.scope == "account")
        #expect(!target.isFolderScoped)
        #expect(target.accountName == "On My Mac")
        #expect(target.id.isEmpty)
    }

    @Test("An unknown account is refused, and the refusal lists the real ones")
    func unknownAccount() throws {
        let context = try fixture()
        context.resolve(["", "Gmail", ""])
        let failure = context.failure()
        #expect(failure.contains(NotesFolderTargeting.notFoundPrefix))
        #expect(failure.contains("iCloud, On My Mac"))
    }

    @Test("An unknown folder is refused, and says which account was searched")
    func unknownFolder() throws {
        let context = try fixture()
        context.resolve(["Archive", "iCloud", ""])
        let failure = context.failure()
        #expect(failure.contains(NotesFolderTargeting.notFoundPrefix))
        #expect(failure.contains("iCloud"))
    }

    @Test("A name that exists only in the other account is refused, not borrowed")
    func nameInWrongAccount() throws {
        let context = try fixture()
        context.resolve(["Work", "On My Mac", ""])
        #expect(context.failure().contains(NotesFolderTargeting.notFoundPrefix))
    }

    @Test("An unknown id is refused rather than falling back to the name")
    func unknownId() throws {
        let context = try fixture()
        context.resolve(["Work", "", "folder-from-another-mac"])
        let failure = context.failure()
        #expect(failure.contains(NotesFolderTargeting.notFoundPrefix))
        #expect(failure.contains("folder-from-another-mac"))
    }

    @Test("Two accounts sharing a name are refused rather than picking one")
    func duplicateAccountNames() throws {
        let context = try fixture(
            accounts: """
                [
                    { name: 'iCloud', folders: [{ id: 'a', name: 'Notes' }] },
                    { name: 'iCloud', folders: [{ id: 'b', name: 'Notes' }] }
                ]
                """
        )
        context.resolve(["Notes", "iCloud", ""])
        #expect(context.failure().contains(NotesFolderTargeting.ambiguousAccountPrefix))
    }

    private func fixture(accounts: String = NotesFolderTargetingTests.twoAccounts) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            const fixtureAccounts = \(accounts);
            function wrapFolder(folder) {
                return { id: () => folder.id, name: () => folder.name };
            }
            function wrapAccount(account) {
                return {
                    name: () => account.name,
                    folders: () => account.folders.map(wrapFolder)
                };
            }
            const wrapped = fixtureAccounts.map(wrapAccount);
            function Application(name) {
                if (name !== 'Notes') throw new Error('Unexpected application');
                const accounts = () => wrapped;
                accounts.whose = predicate => () =>
                    wrapped.filter(a => a.name() === predicate.name);
                return { accounts: accounts };
            }
            """
        )
        context.evaluateScript(NotesFolderTargeting.resolveScript)
        #expect(context.exception == nil)
        return context
    }
}

extension JSContext {
    @discardableResult
    fileprivate func resolve(_ arguments: [String]) -> JSValue? {
        objectForKeyedSubscript("run").call(withArguments: [arguments])
    }

    fileprivate func failure() -> String {
        exception?.toString() ?? "<no exception>"
    }

    fileprivate func target(_ arguments: [String]) throws -> NotesFolderTarget {
        let result = resolve(arguments)
        #expect(exception == nil, "\(exception?.toString() ?? "")")
        let json = try #require(result?.toString())
        return try JSONDecoder().decode(NotesFolderTarget.self, from: Data(json.utf8))
    }
}
