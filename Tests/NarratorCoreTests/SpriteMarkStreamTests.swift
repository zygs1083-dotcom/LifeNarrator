import Foundation
import Testing
@testable import NarratorCore

let streamJSON = #"{"marks":[{"l":0,"q":"quoted } \"text\"","t":"一句旁白","e":"😬"},{"l":1,"q":"another phrase","t":"另一句","e":"👨‍👩‍👧‍👦"},{"l":2,"q":"last phrase","t":"最后一句","e":"🌷"}]}"#

@Test func spriteStreamCompleteAndCharacterFeedsMatchWithoutDuplicates() throws {
    var complete = SpriteMarkStream()
    let expected = try complete.feed(streamJSON)
    #expect(expected.count == 3)
    #expect(expected[0].q == "quoted } \"text\"")
    #expect(try complete.feed(streamJSON).isEmpty)
    var stream = SpriteMarkStream()
    var partial = ""
    var actual: [RawMark] = []
    for scalar in streamJSON.unicodeScalars {
        partial.unicodeScalars.append(scalar)
        actual += try stream.feed(partial)
    }
    #expect(actual == expected)
}

@Test func spriteStreamEmptyAndTruncatedObjectsEmitNothing() throws {
    var empty = SpriteMarkStream()
    #expect(try empty.feed(#"{"marks":[]}"#).isEmpty)
    var truncated = SpriteMarkStream()
    #expect(try truncated.feed(#"{"marks":[{"l":0,"q":"unfinished""#).isEmpty)
    var malformed = SpriteMarkStream()
    #expect(throws: DecodingError.self) { try malformed.feed(#"{"marks":[{"l":0}]}"#) }
}
