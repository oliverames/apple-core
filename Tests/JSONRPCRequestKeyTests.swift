import Testing

@Suite("JSON-RPC request keys")
struct JSONRPCRequestKeyTests {
    @Test("String and numeric identifiers do not collide")
    func identifierTypesRemainDistinct() throws {
        let numeric = try #require(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","id":1}"#))
        let string = try #require(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","id":"1"}"#))

        #expect(numeric != string)
        #expect(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","method":"ping"}"#) == nil)
        #expect(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","id":null}"#) == nil)
        #expect(JSONRPCRequestKey.from(message: #"{"jsonrpc":"2.0","id":true}"#) == nil)
    }

    @Test("Inbound messages reject malformed and batched JSON before session allocation")
    func inboundMessageValidation() {
        #expect(
            JSONRPCRequestKey.classifyInbound(
                message: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
            ) == .request(requestKey: "number:1", method: "initialize")
        )
        #expect(
            JSONRPCRequestKey.classifyInbound(
                message: #"{"jsonrpc":"2.0","id":1.0,"method":"ping","params":{}}"#
            ) == .request(requestKey: "number:1", method: "ping")
        )
        #expect(
            JSONRPCRequestKey.classifyInbound(
                message: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            ) == .notificationOrResponse
        )
        #expect(
            JSONRPCRequestKey.classifyInbound(
                message: #"{"jsonrpc":"2.0","id":"server-1","result":{}}"#
            ) == .notificationOrResponse
        )

        for invalid in [
            "{",
            "null",
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
            #"{"id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":9223372036854775808,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1}"#,
            #"{"jsonrpc":"2.0","id":1,"result":{},"error":{}}"#,
        ] {
            #expect(JSONRPCRequestKey.classifyInbound(message: invalid) == .invalid)
        }
    }

    @Test("Only initialize requests may create a session")
    func sessionCreationPolicy() {
        let initialize = JSONRPCRequestKey.classifyInbound(
            message: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        )
        let request = JSONRPCRequestKey.classifyInbound(
            message: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        )
        let notification = JSONRPCRequestKey.classifyInbound(
            message: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        )

        #expect(initialize.canStartSession)
        #expect(!request.canStartSession)
        #expect(!notification.canStartSession)
    }

    @Test("Cancellation identifiers preserve their JSON type")
    func cancellationIdentifiersPreserveType() {
        let numeric = JSONRPCRequestKey.cancelledRequestKey(
            from: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#
        )
        let string = JSONRPCRequestKey.cancelledRequestKey(
            from: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"1"}}"#
        )

        #expect(numeric == "number:1")
        #expect(string == "string:1")
        #expect(numeric != string)

        for invalid in [
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":true}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1.5}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"requestId":1}}"#,
        ] {
            #expect(JSONRPCRequestKey.cancelledRequestKey(from: invalid) == nil)
        }
    }
}
