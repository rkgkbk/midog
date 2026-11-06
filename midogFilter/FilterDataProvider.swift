import Foundation
import NetworkExtension

/// The signed extension and mihomo both bundle the same category-porn.list source.
final class FilterDataProvider: NEFilterDataProvider {
    private var blocklist = Blocklist("")
    private var focus: FocusAuthority?
    private let lock = NSLock()
    private var focusState = FocusState()
    private var flows: [UUID: NEFilterSocketFlow] = [:]

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        guard let url = Bundle.main.url(forResource: "category-porn", withExtension: "list"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            completionHandler(NSError(domain: "com.xx.midog.filter", code: 1))
            return
        }
        blocklist = Blocklist(contents)
        let authority = FocusAuthority()
        focus = authority
        authority.rulesChanged = { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            self.focusState = state
            let blocked = self.flows.values.filter { state.isFilteringEnabled() && (self.blocklist.blocks(self.hostname($0) ?? "") || state.blocks(self.hostname($0) ?? "")) }
            self.lock.unlock()
            for flow in blocked { self.update(flow, using: .drop(), for: .any) }
        }
        do {
            try authority.start()
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        focus?.stop()
        focus = nil
        lock.lock(); flows.removeAll(); midog_proxy_cache_clear(); lock.unlock()
        completionHandler()
    }

    private func hostname(_ flow: NEFilterFlow) -> String? {
        flow.url?.host ?? (flow as? NEFilterSocketFlow)?.remoteHostname
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let host = hostname(flow)
        lock.lock()
        defer { lock.unlock() }
        if !focusState.isFilteringEnabled() {
            if let socket = flow as? NEFilterSocketFlow { flows[flow.identifier] = socket }
            let verdict = NEFilterNewFlowVerdict.allow()
            verdict.shouldReport = true
            return verdict
        }
        // Proxy tunnels often expose only a server IP, so check the originating process first.
        for token in [flow.sourceAppAuditToken, flow.sourceProcessAuditToken].compactMap({ $0 }) {
            if token.withUnsafeBytes({ midog_proxy_flow($0.baseAddress, $0.count) }) { return .drop() }
        }
        if let host, blocklist.blocks(host) || focusState.blocks(host) { return .drop() }
        if host != nil, let socket = flow as? NEFilterSocketFlow {
            // Retain tracked sockets until their close report so additions also stop existing traffic.
            flows[flow.identifier] = socket
        }
        let verdict = NEFilterNewFlowVerdict.allow()
        verdict.shouldReport = true
        return verdict
    }

    override func handle(_ report: NEFilterReport) {
        if report.event == .flowClosed, let flow = report.flow {
            lock.lock(); flows.removeValue(forKey: flow.identifier); lock.unlock()
        }
    }
}
