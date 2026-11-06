import Foundation
import Security

@objc nonisolated protocol FocusRemote {
    func perform(_ request: Data, reply: @escaping (Data) -> Void)
}

nonisolated enum FocusIPC {
    // Separate generations so retiring an old extension cannot unregister the new listener.
    static var service: String {
        "group.com.xx.midog.focus." + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }
    static let directory = URL(fileURLWithPath: "/Library/Application Support/midog-focus", isDirectory: true)
    static let rulesFile = directory.appendingPathComponent("domains.list")
    static let adultRulesFile = directory.appendingPathComponent("adult.list")
    static let adultProviderName = "__MIDOG_ADULT_BLOCK"
    static let providerName = "__MIDOG_FOCUS"

    /// Pin both ends to the same signing team. Ad-hoc builds are development only.
    static func requirement(identifier: String) throws -> String {
        var code: SecCode?
        var info: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { throw FocusFailure("无法读取应用签名") }
        if let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
           team.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil {
            return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        #if DEBUG
        return "identifier \"\(identifier)\""
        #else
        throw FocusFailure("专注服务需要有效的开发者签名")
        #endif
    }
}
