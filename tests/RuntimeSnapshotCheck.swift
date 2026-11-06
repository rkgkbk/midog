import Foundation

@main
enum RuntimeSnapshotCheck {
    static func main() throws {
        let decoder = JSONDecoder()
        func proxies(_ json: String) throws -> [String: ProxyNode] {
            try decoder.decode([String: ProxyNode].self, from: Data(json.utf8))
        }
        let first = try proxies(#"{"PROXY":{"type":"Selector","now":"A","all":["A","B"]}}"#)
        let same = try proxies(#"{"PROXY":{"all":["A","B"],"now":"A","type":"Selector"}}"#)
        precondition(first == same)
        var changed = same
        changed["PROXY"]?.now = "B"
        precondition(first != changed, "Node switches must still refresh the UI")
        changed = same
        changed["PROXY"]?.all = ["A", "B", "C"]
        precondition(first != changed, "Subscription membership changes must remain visible")
        let old = RuleProviderRuntime(ruleCount: 10, updatedAt: "old")
        precondition(old == RuleProviderRuntime(ruleCount: 10, updatedAt: "old"))
        precondition(old != RuleProviderRuntime(ruleCount: 11, updatedAt: "old"))
        precondition(old != RuleProviderRuntime(ruleCount: 10, updatedAt: "new"))
        print("Runtime snapshot equality: unchanged, selected node, membership and rules passed")
    }
}
