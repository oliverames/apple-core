import Testing

@Suite("Sensitive text sanitizer")
struct SensitiveTextSanitizerTests {
    @Test("Assignments and embedded environment values are fully redacted")
    func redactsWholeSecrets() {
        let environment = [
            "TUNNEL_TOKEN": "token-sentinel",
            "TUNNEL_CRED_CONTENTS": #"{"secret":"credential-sentinel"}"#,
            "CLOUDFLARE_API_TOKEN": "api-sentinel",
        ]
        let input = """
            TUNNEL_TOKEN=token-sentinel
            TUNNEL_CRED_CONTENTS='credential-sentinel'
            TUNNEL_CRED_CONTENTS="{\\\"TunnelSecret\\\":\\\"escaped-sentinel\\\"}"
            TUNNEL_TOKEN = spaced-sentinel
            CLOUDFLARE_API_TOKEN=first-sentinel second-sentinel
            header api-sentinel footer
            """

        let sanitized = SensitiveTextSanitizer.redactAssignmentsAndValues(
            in: input,
            keys: Array(environment.keys),
            environment: environment
        )

        #expect(!sanitized.contains("token-sentinel"))
        #expect(!sanitized.contains("credential-sentinel"))
        #expect(!sanitized.contains("api-sentinel"))
        #expect(!sanitized.contains("escaped-sentinel"))
        #expect(!sanitized.contains("spaced-sentinel"))
        #expect(!sanitized.contains("first-sentinel"))
        #expect(!sanitized.contains("second-sentinel"))
        #expect(sanitized.contains("TUNNEL_TOKEN=[redacted]"))
    }
}
