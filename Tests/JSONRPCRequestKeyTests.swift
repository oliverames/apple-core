import Testing

@Suite("JSON-RPC request keys")
struct JSONRPCRequestKeyTests {
    @Test("String and numeric identifiers do not collide")
    func identifierTypesRemainDistinct() throws {
        let numeric = try #require(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","id":1}"#))
        let string = try #require(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","id":"1"}"#))

        #expect(numeric != string)
        #expect(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","method":"ping"}"#) == nil)
        #expect(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","id":true}"#) == nil)
    }
}
