import Foundation
import ServiceManagement

/// Login-item registration through SMAppService — the modern replacement for
/// poking at System Events, and it needs no extra automation permission.
/// The app shows up in システム設定 › 一般 › ログイン項目 under its own name.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled:        return "オン"
        case .notRegistered:  return "オフ"
        case .requiresApproval: return "システム設定で承認が必要"
        case .notFound:       return "登録できません"
        @unknown default:     return "不明"
        }
    }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "ログイン項目の変更に失敗しました: \(error.localizedDescription)"
        }
    }
}
