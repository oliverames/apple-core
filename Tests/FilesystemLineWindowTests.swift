import Foundation
import Testing

@Suite("Head and tail line windows")
struct FilesystemLineWindowTests {
    @Test("Head returns the first lines and says when there are more")
    func head() {
        let text = "one\ntwo\nthree\nfour\n"
        let first = FilesystemLineWindow.head(text, count: 2, isWholeFile: true)
        #expect(first.lines == ["one", "two"])
        #expect(first.truncated)
        #expect(!first.startedMidFile)

        let all = FilesystemLineWindow.head(text, count: 10, isWholeFile: true)
        #expect(all.lines == ["one", "two", "three", "four"])
        #expect(!all.truncated)
    }

    @Test("A chunk that is not the whole file is truncated even when its lines fit")
    func headOfAChunk() {
        let result = FilesystemLineWindow.head("one\ntwo\n", count: 10, isWholeFile: false)
        #expect(result.lines == ["one", "two"])
        #expect(result.truncated)
    }

    @Test("Tail returns the last lines")
    func tail() {
        let text = "one\ntwo\nthree\nfour\n"
        let last = FilesystemLineWindow.tail(text, count: 2, startsMidFile: false)
        #expect(last.lines == ["three", "four"])
        #expect(last.truncated)

        let all = FilesystemLineWindow.tail(text, count: 10, startsMidFile: false)
        #expect(all.lines == ["one", "two", "three", "four"])
        #expect(!all.truncated)
    }

    @Test("A tail that started mid-file drops the fragment it landed in")
    func tailDropsTheFragment() {
        // The read began inside "three".
        let result = FilesystemLineWindow.tail("ree\nfour\nfive\n", count: 5, startsMidFile: true)
        #expect(result.lines == ["four", "five"])
        #expect(result.truncated)
        #expect(result.startedMidFile)
    }

    @Test("A trailing newline does not invent an empty last line")
    func trailingNewline() {
        #expect(FilesystemLineWindow.split("a\nb\n") == ["a", "b"])
        #expect(FilesystemLineWindow.split("a\nb") == ["a", "b"])
        // A genuinely blank line in the middle is kept.
        #expect(FilesystemLineWindow.split("a\n\nb\n") == ["a", "", "b"])
        #expect(FilesystemLineWindow.split("") == [])
    }

    @Test("Windows line endings do not leave a carriage return on every line")
    func windowsLineEndings() {
        #expect(FilesystemLineWindow.split("a\r\nb\r\n") == ["a", "b"])
    }

    @Test("A window starting mid-character still decodes")
    func decodesFromMidCharacter() throws {
        let text = "é is two bytes\nsecond line\n"
        let data = Data(text.utf8)
        // Start one byte into the two-byte "é".
        let window = data.dropFirst(1)

        #expect(String(data: window, encoding: .utf8) == nil)
        let decoded = try #require(FilesystemLineWindow.decode(Data(window), startsMidFile: true))
        #expect(decoded.hasPrefix(" is two bytes"))

        // The same bytes claimed to be a whole file are not text, and are not
        // silently repaired into text.
        #expect(FilesystemLineWindow.decode(Data(window), startsMidFile: false) == nil)
    }

    @Test("Binary data is not text, however it is asked for")
    func refusesBinary() {
        let data = Data([0xFF, 0xFE, 0x00, 0x01, 0xFF])
        #expect(FilesystemLineWindow.decode(data, startsMidFile: false) == nil)
        #expect(FilesystemLineWindow.decode(data, startsMidFile: true) == nil)
    }

    @Test("Line counts clamp to the documented bounds")
    func clamps() {
        #expect(FilesystemLineWindow.clampedLines(0) == 1)
        #expect(FilesystemLineWindow.clampedLines(-5) == 1)
        #expect(FilesystemLineWindow.clampedLines(20) == 20)
        #expect(FilesystemLineWindow.clampedLines(99_999) == FilesystemLineWindow.maximumLines)
    }
}
