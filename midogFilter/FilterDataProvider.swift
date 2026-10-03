import Foundation
import NetworkExtension

/// The signed extension and mihomo both bundle the same category-porn.list source.
final class FilterDataProvider: NEFilterDataProvider {
    private var blocklist = Blocklist("")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        guard let url = Bundle.main.url(forResource: "category-porn", withExtension: "list"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            completionHandler(NSError(domain: "com.xx.midog.filter", code: 1))
            return
        }

        blocklist = Blocklist(contents)
        completionHandler(nil)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let host = flow.url?.host ?? (flow as? NEFilterSocketFlow)?.remoteHostname
        guard let host else { return .allow() }
        return blocklist.blocks(host) ? .drop() : .allow()
    }
}
