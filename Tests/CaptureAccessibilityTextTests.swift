import Foundation
import Testing

/// A constructed accessibility tree. The real one only exists against a
/// running application, which is precisely why the rules being tested here
/// live in `CaptureAccessibilityText` rather than in the tool closure.
private struct FakeElement: CaptureAccessibleElement {
    var axRole: String?
    var axSubrole: String?
    var axTitle: String?
    var axValueText: String?
    var axDescriptionText: String?
    var axChildren: [FakeElement] = []

    init(
        role: String? = "AXGroup",
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        children: [FakeElement] = []
    ) {
        self.axRole = role
        self.axSubrole = subrole
        self.axTitle = title
        self.axValueText = value
        self.axDescriptionText = description
        self.axChildren = children
    }
}

@Suite("Accessibility text reading")
struct CaptureAccessibilityTextTests {
    @Test("Text is collected from a window's elements")
    func collectsText() {
        let window = FakeElement(
            role: "AXWindow",
            title: "Inbox",
            children: [
                FakeElement(role: "AXStaticText", value: "From Alice"),
                FakeElement(role: "AXStaticText", value: "Subject: lunch"),
            ]
        )
        let result = CaptureAccessibilityText.read(root: window)
        #expect(result.text == "Inbox\nFrom Alice\nSubject: lunch")
        #expect(result.isBounded == false)
    }

    @Test("A secure field contributes nothing, and neither do its children")
    func secureFieldsExcluded() {
        let window = FakeElement(
            role: "AXWindow",
            title: "Sign in",
            children: [
                FakeElement(role: "AXTextField", value: "oliver@example.com"),
                FakeElement(
                    role: "AXTextField",
                    subrole: "AXSecureTextField",
                    value: "hunter2",
                    children: [FakeElement(role: "AXStaticText", value: "hunter2")]
                ),
                FakeElement(role: "AXSecureTextField", value: "swordfish"),
            ]
        )
        let result = CaptureAccessibilityText.read(root: window)
        #expect(!result.text.contains("hunter2"))
        #expect(!result.text.contains("swordfish"))
        #expect(result.text.contains("oliver@example.com"))
        #expect(result.secureElementsExcluded == 2)
    }

    @Test("Both spellings of a secure field are recognised")
    func secureRoles() {
        #expect(CaptureAccessibilityText.isSecure(role: "AXSecureTextField", subrole: nil))
        #expect(CaptureAccessibilityText.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(!CaptureAccessibilityText.isSecure(role: "AXTextField", subrole: "AXSearchField"))
        #expect(!CaptureAccessibilityText.isSecure(role: nil, subrole: nil))
    }

    @Test("The node budget stops the walk and is reported")
    func nodeBudget() {
        let window = FakeElement(
            role: "AXWindow",
            title: "Long",
            children: (0 ..< 50).map { FakeElement(role: "AXStaticText", value: "line \($0)") }
        )
        let result = CaptureAccessibilityText.read(root: window, maxNodes: 5)
        #expect(result.reachedNodeLimit)
        #expect(result.nodes.count <= 5)
    }

    @Test("The character budget stops the walk and is reported")
    func characterBudget() {
        let window = FakeElement(
            role: "AXWindow",
            children: (0 ..< 20).map {
                FakeElement(role: "AXStaticText", value: String(repeating: "\($0)", count: 100))
            }
        )
        let result = CaptureAccessibilityText.read(root: window, maxCharacters: 250)
        #expect(result.reachedCharacterLimit)
        #expect(result.text.count <= 250)
    }

    @Test("The depth budget stops the descent and is reported")
    func depthBudget() {
        var deepest = FakeElement(role: "AXStaticText", value: "bottom")
        for level in (0 ..< 5).reversed() {
            deepest = FakeElement(role: "AXGroup", value: "level \(level)", children: [deepest])
        }
        let result = CaptureAccessibilityText.read(root: deepest, maxDepth: 2)
        #expect(result.reachedDepthLimit)
        #expect(!result.text.contains("bottom"))
    }

    @Test("One element's own text is capped, so a document value cannot flood the read")
    func perNodeCap() {
        let huge = String(repeating: "a", count: CaptureAccessibilityText.maximumNodeCharacters * 3)
        let element = FakeElement(role: "AXTextArea", value: huge)
        #expect(
            CaptureAccessibilityText.text(of: element)?.count
                == CaptureAccessibilityText.maximumNodeCharacters
        )
    }

    @Test("Value wins over title, and whitespace-only text is not text")
    func textPreference() {
        #expect(
            CaptureAccessibilityText.text(
                of: FakeElement(title: "Title", value: "Value", description: "Description")
            ) == "Value"
        )
        #expect(
            CaptureAccessibilityText.text(of: FakeElement(title: "Title", value: "   ")) == "Title"
        )
        #expect(CaptureAccessibilityText.text(of: FakeElement()) == nil)
    }

    @Test("A label repeated by its container is not repeated in the output")
    func deduplicates() {
        let window = FakeElement(
            role: "AXWindow",
            title: "Save",
            children: [
                FakeElement(role: "AXButton", title: "Save"),
                FakeElement(role: "AXButton", title: "Cancel"),
            ]
        )
        let result = CaptureAccessibilityText.read(root: window)
        #expect(result.text == "Save\nCancel")
    }

    @Test("Bounds are clamped rather than trusted")
    func clamping() {
        #expect(CaptureAccessibilityText.clampedNodes(nil) == CaptureAccessibilityText.defaultMaxNodes)
        #expect(
            CaptureAccessibilityText.clampedNodes(999_999) == CaptureAccessibilityText.maximumMaxNodes
        )
        #expect(
            CaptureAccessibilityText.clampedCharacters(-5)
                == CaptureAccessibilityText.defaultMaxCharacters
        )
        #expect(CaptureAccessibilityText.clampedDepth(4) == 4)
    }

    @Test("Accessibility readiness says which permission is missing")
    func readiness() {
        #expect(CaptureAccessibilityReadiness.status(isTrusted: true) == "ready")
        #expect(CaptureAccessibilityReadiness.status(isTrusted: false) == "permissionRequired")
        #expect(CaptureAccessibilityReadiness.detail(isTrusted: false).contains("Accessibility"))
    }
}
