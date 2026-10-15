import Foundation
import Security

@objc nonisolated protocol FocusRemote {
    func perform(_ request: Data, reply: @escaping (Data) -> Void)
}

nonisolated enum FocusIPC {
    static let service = "group.com.xx.midog.focus"
    static let directory = URL(fileURLWithPath: "/Library/Application Support/midog-focus", isDirectory: true)
    static let rulesFile = directory.appendingPathComponent("domains.list")
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
