import Foundation
import Testing

@Suite("Cloudflare tunnel ownership")
struct CloudflareTunnelOwnershipTests {
    @Test("A config with no recorded owner is unowned")
    func legacyConfigIsUnowned() {
        #expect(
            CloudflareTunnelOwnershipRules.ownership(
                ownerMachineID: "",
                ownerMachineName: "",
                currentMachineID: "mac-a"
            )
                == .unowned
        )
        #expect(
            CloudflareTunnelOwnershipRules.ownership(
                ownerMachineID: "  ",
                ownerMachineName: "x",
                currentMachineID: "mac-a"
            )
                == .unowned
        )
    }

    @Test("Ownership compares the recorded Mac to the one asking")
    func ownershipDecision() {
        #expect(
            CloudflareTunnelOwnershipRules.ownership(
                ownerMachineID: "mac-a",
                ownerMachineName: "Home Server",
                currentMachineID: "mac-a"
            ) == .thisMac
        )
        #expect(
            CloudflareTunnelOwnershipRules.ownership(
                ownerMachineID: "mac-a",
                ownerMachineName: "Home Server",
                currentMachineID: "mac-b"
            ) == .otherMac(name: "Home Server")
        )
        #expect(
            CloudflareTunnelOwnershipRules.ownership(
                ownerMachineID: "mac-a",
                ownerMachineName: "",
                currentMachineID: "mac-b"
            )
                == .otherMac(name: "another Mac")
        )
    }

    @Test("The stand-down message names the owner and the address")
    func ownedElsewhereMessage() {
        let message = CloudflareTunnelOwnershipRules.ownedElsewhereMessage(
            owner: "Home Server",
            hostname: "mcp.example.com"
        )
        #expect(message.contains("Home Server"))
        #expect(message.contains("mcp.example.com"))
        #expect(
            CloudflareTunnelOwnershipRules.ownedElsewhereMessage(owner: "Home Server", hostname: "").contains(
                "this tunnel"
            )
        )
    }

    @Test("cloudflared tunnel info counts one connector per running cloudflared")
    func parsesConnectorCount() {
        let json = """
            {"id": "t", "name": "apple-core", "conns": [
              {"id": "a", "conns": [{"colo_name": "bos01", "origin_ip": "69.53.27.92"}]},
              {"id": "b", "conns": [{"colo_name": "yyz04", "origin_ip": "69.53.27.92"},
                                    {"colo_name": "bos03", "origin_ip": "10.0.0.2"}]}
            ]}
            """
        let report = CloudflareTunnelOwnershipRules.parseTunnelInfo(Data(json.utf8))
        #expect(report == CloudflareConnectorReport(connectorCount: 2, originIPs: ["69.53.27.92", "10.0.0.2"]))
    }

    @Test("A tunnel with nobody connected is zero, not nil")
    func parsesEmptyConnectors() {
        let report = CloudflareTunnelOwnershipRules.parseTunnelInfo(Data(#"{"id": "t", "conns": []}"#.utf8))
        #expect(report == CloudflareConnectorReport(connectorCount: 0, originIPs: []))
    }

    @Test("A cloudflared error is not read as zero connectors")
    func rejectsNonTunnelInfo() {
        #expect(CloudflareTunnelOwnershipRules.parseTunnelInfo(Data("error: not logged in".utf8)) == nil)
        #expect(CloudflareTunnelOwnershipRules.parseTunnelInfo(Data(#"{"id": "t"}"#.utf8)) == nil)
    }

    @Test("Machine identity is stable and non-empty")
    func machineIdentity() {
        let id = MachineIdentity.currentID()
        #expect(!id.isEmpty)
        #expect(id == MachineIdentity.currentID())
        #expect(!MachineIdentity.currentName().isEmpty)
    }
}
