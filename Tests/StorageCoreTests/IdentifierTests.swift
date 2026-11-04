import Testing
import StorageCore

@Suite struct IdentifierTests {
    @Test(arguments: ["", " ", "\n\t "])
    func blankText(_ text: String) {
        #expect(Identifier.isBlank(text))
    }

    @Test func nonBlankText() {
        #expect(!Identifier.isBlank(" a "))
    }

    @Test(arguments: ["demo", "demo-app", "app2", "1password"])
    func kebabCase(_ id: String) {
        #expect(Identifier.isKebabCase(id))
    }

    @Test(arguments: ["Bad_Id", "Demo", "-demo", "demo-", "de--mo", "", "démo", "de mo"])
    func notKebabCase(_ id: String) {
        #expect(!Identifier.isKebabCase(id))
    }

    @Test(arguments: ["com.example.Demo", "notion.id", "com.todesktop.230313mzl4w4u92", "com.example.demo-app"])
    func reverseDNS(_ id: String) {
        #expect(Identifier.isReverseDNS(id))
    }

    @Test(arguments: ["", "Demo", "com.example.Demo App", ".com.example", "com..example", "com.example."])
    func notReverseDNS(_ id: String) {
        #expect(!Identifier.isReverseDNS(id))
    }
}
