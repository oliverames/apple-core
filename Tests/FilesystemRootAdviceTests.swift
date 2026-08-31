// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings list showed every shared folder identically, so sharing one
// project directory and sharing the whole home folder read-write looked the
// same. These cover the judgement that closes that gap, and in particular
// that an ordinary folder stays quiet: advice nobody needs is noise, and
// noise is what gets ignored when it matters.

import Foundation
import Testing

@Suite("Shared folder scope advice")
struct FilesystemRootAdviceTests {
    private static let home = "/Users/testuser"

    private static func advice(
        _ path: String,
        writable: Bool = false,
        among others: [FilesystemRoot] = []
    ) -> FilesystemRootAdvice {
        FilesystemAccess.advice(
            for: FilesystemRoot(path: path, writable: writable),
            among: others,
            homeDirectory: home
        )
    }

    @Test("An ordinary folder says nothing at all")
    func ordinaryFolderIsQuiet() {
        let result = Self.advice("\(Self.home)/Documents/Projects")
        #expect(result.scope == .ordinary)
        #expect(result.message == nil)
        #expect(!result.isSerious)
    }

    @Test("The home folder is called out, and worse when writable")
    func homeFolderIsCalledOut() {
        let readOnly = Self.advice(Self.home)
        #expect(readOnly.scope == .entireHomeFolder)
        #expect(readOnly.isSerious)
        #expect(readOnly.message?.contains("whole Home folder") == true)

        let writable = Self.advice(Self.home, writable: true)
        #expect(writable.message?.contains("read and change") == true)
    }

    @Test("A volume root is treated as the whole disk")
    func diskRootIsCalledOut() {
        let result = Self.advice("/")
        #expect(result.scope == .entireDisk)
        #expect(result.isSerious)
    }

    @Test("A folder above the home folder is the whole disk too")
    func aboveHomeIsDisk() {
        // /Users contains the home folder, so sharing it is not merely "a
        // folder" even though it is not literally the volume root.
        #expect(Self.advice("/Users").scope == .entireDisk)
    }

    @Test("A folder inside another shared folder is reported as redundant")
    func nestedFolderIsRedundant() {
        // Exactly the shape found on the live server: Documents and Desktop
        // shared alongside the home folder that already contained them.
        let result = Self.advice(
            "\(Self.home)/Documents",
            among: [FilesystemRoot(path: Self.home, writable: true)]
        )
        #expect(result.scope == .alreadyCovered(by: "your Home folder"))
        #expect(result.message?.contains("adds nothing") == true)
        // Redundancy is untidy, not dangerous. Only the parent should shout.
        #expect(!result.isSerious)
    }

    @Test("A sibling folder is not mistaken for a parent")
    func siblingIsNotAParent() {
        // "Documents-private" must not read as being inside "Documents".
        let result = Self.advice(
            "\(Self.home)/Documents-private",
            among: [FilesystemRoot(path: "\(Self.home)/Documents", writable: false)]
        )
        #expect(result.scope == .ordinary)
    }

    @Test("A folder is never reported as covering itself")
    func selfIsNotItsOwnParent() {
        let path = "\(Self.home)/Documents"
        let result = Self.advice(path, among: [FilesystemRoot(path: path, writable: false)])
        #expect(result.scope == .ordinary)
    }

    @Test("The home folder outranks being nested inside another entry")
    func homeWinsOverRedundancy() {
        // Sharing "/" and the home folder together must still shout about the
        // home folder rather than filing it away as redundant.
        let result = Self.advice(Self.home, among: [FilesystemRoot(path: "/", writable: true)])
        #expect(result.scope == .entireHomeFolder)
    }

    @Test("The home folder is named in words, not as a path")
    func homeIsNamedInWords() {
        #expect(FilesystemAccess.displayName(for: Self.home, homeDirectory: Self.home) == "your Home folder")
        #expect(
            FilesystemAccess.displayName(for: "\(Self.home)/Documents", homeDirectory: Self.home)
                == "Documents"
        )
    }
}
