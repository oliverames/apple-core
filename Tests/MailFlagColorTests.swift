// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@Suite("Mail flag colours")
struct MailFlagColorTests {
    @Test("Every colour maps to the flag index Mail uses")
    func indexesMatchMail() {
        #expect(MailFlagColor.red.index == 0)
        #expect(MailFlagColor.orange.index == 1)
        #expect(MailFlagColor.yellow.index == 2)
        #expect(MailFlagColor.green.index == 3)
        #expect(MailFlagColor.blue.index == 4)
        #expect(MailFlagColor.purple.index == 5)
        #expect(MailFlagColor.gray.index == 6)
        #expect(Set(MailFlagColor.allCases.map(\.index)).count == 7)
    }

    @Test("An index round-trips back to its colour")
    func roundTrip() {
        for color in MailFlagColor.allCases {
            #expect(MailFlagColor.named(index: color.index) == color)
        }
    }

    @Test("An index Mail does not define is not guessed at")
    func unknownIndexIsNil() {
        // -1 is Mail's 'flagged, colour unset'; 7 is a future Mail's problem.
        #expect(MailFlagColor.named(index: -1) == nil)
        #expect(MailFlagColor.named(index: 7) == nil)
    }

    @Test("Names parse case- and spelling-insensitively")
    func nameParsing() {
        #expect(MailFlagColor.named("Red") == .red)
        #expect(MailFlagColor.named("  BLUE ") == .blue)
        #expect(MailFlagColor.named("grey") == .gray)
        #expect(MailFlagColor.named("gray") == .gray)
        #expect(MailFlagColor.named("chartreuse") == nil)
    }

    @Test("Omitting a colour gives a plain flag or unflag")
    func plainInstructions() throws {
        #expect(try MailFlagInstruction.resolve(flagged: true, color: nil) == .flag)
        #expect(try MailFlagInstruction.resolve(flagged: false, color: nil) == .unflag)
        // An empty string is an omitted colour, not an unknown one.
        #expect(try MailFlagInstruction.resolve(flagged: true, color: "  ") == .flag)
    }

    @Test("A colour resolves to that colour")
    func colorInstruction() throws {
        #expect(try MailFlagInstruction.resolve(flagged: true, color: "purple") == .color(.purple))
    }

    @Test("Unflagging in a colour is refused rather than half-obeyed")
    func contradictionRefused() {
        #expect(throws: MailFlagColorError.contradictoryRequest) {
            try MailFlagInstruction.resolve(flagged: false, color: "red")
        }
    }

    @Test("An unknown colour names the ones that would have worked")
    func unknownColorListsOptions() {
        do {
            _ = try MailFlagInstruction.resolve(flagged: true, color: "octarine")
            Issue.record("expected an unknown-colour failure")
        } catch let failure as MailFlagColorError {
            #expect(failure.description.contains("octarine"))
            #expect(failure.description.contains("purple"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("The script argument is the token the JXA write reads")
    func scriptArguments() {
        #expect(MailFlagInstruction.unflag.scriptArgument == "unflag")
        #expect(MailFlagInstruction.flag.scriptArgument == "flag")
        #expect(MailFlagInstruction.color(.green).scriptArgument == "3")
    }
}
