import Foundation
import NetworkExtension
import SystemExtensions

@MainActor
final class ContentFilterInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = ContentFilterInstaller()
    private let identifier = "com.xx.midog.filter"

    func install() {
        guard !Store.shared.contentFilterBusy else { return }
        Store.shared.contentFilterBusy = true
        Store.shared.contentFilterStatus = "正在请求系统内容过滤授权"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Store.shared.contentFilterStatus = "等待在系统设置中批准内容过滤扩展"
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if result == .willCompleteAfterReboot {
            Store.shared.contentFilterStatus = "请重启后重新打开 midog，以完成系统内容过滤配置"
            Store.shared.contentFilterBusy = false
            return
        }
        Task {
            defer { Store.shared.contentFilterBusy = false }
            do {
                let manager = NEFilterManager.shared()
                try await manager.loadFromPreferences()
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterDataProviderBundleIdentifier = identifier
                manager.providerConfiguration = configuration
                manager.localizedDescription = "midog 强制域名过滤"
                manager.isEnabled = true
                try await manager.saveToPreferences()
                Store.shared.contentFilterStatus = "系统内容过滤已配置，请确认系统设置中已启用"
            } catch {
                Store.shared.contentFilterStatus = "系统内容过滤未启用：\(error.localizedDescription)"
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Store.shared.contentFilterStatus = "系统内容过滤安装失败：\(error.localizedDescription)"
        Store.shared.contentFilterBusy = false
    }
}
