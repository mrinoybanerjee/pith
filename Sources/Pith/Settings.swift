import Foundation
import PithCore
import ServiceManagement

/// The saved settings (spec 4.6). Launch at login is not saved: macOS's own login item state is the
/// truth (R74). A key that was never saved has its default; a saved value of the wrong type traps.
struct Settings: Equatable {
  /// 2 s while open by default; 1 s by setting (R134).
  var refresh = RefreshSetting.twoSeconds
  var amberOnCPU = true

  static func load(_ defaults: UserDefaults) -> Settings {
    var settings = Settings()
    if let value = defaults.object(forKey: "refresh") {
      settings.refresh = RefreshSetting(rawValue: value as! String)!
    }
    if let value = defaults.object(forKey: "amberOnCPU") { settings.amberOnCPU = value as! Bool }
    return settings
  }

  /// Writes only the settings that differ from what `defaults` gives now: the ones the user
  /// changed. So a launch writes none, and a setting never changed follows each version's default
  /// (R137).
  func save(_ defaults: UserDefaults) {
    let saved = Settings.load(defaults)
    if refresh != saved.refresh { defaults.set(refresh.rawValue, forKey: "refresh") }
    if amberOnCPU != saved.amberOnCPU { defaults.set(amberOnCPU, forKey: "amberOnCPU") }
  }
}

/// Pith's login item (spec 4.6): `SMAppService.mainApp` in the app, a stand-in in tests.
struct LoginItem {
  static let main = LoginItem(
    isEnabled: { SMAppService.mainApp.status == .enabled },
    set: { enabled in
      let app = SMAppService.mainApp
      if enabled, app.status != .enabled { try app.register() }
      if !enabled, app.status != .notRegistered { try app.unregister() }
    })

  /// Whether Pith opens at login now. The user can change it in System Settings at any time.
  let isEnabled: @MainActor @Sendable () -> Bool
  /// Registers Pith or removes it. macOS can refuse, for example for an app outside a bundle.
  let set: @MainActor @Sendable (Bool) throws -> Void
}

extension UserDefaults {
  /// The pinned panel's frame (spec 4.7). It is saved apart from the settings because every drag
  /// changes it.
  var pinnedFrame: CGRect? {
    get { string(forKey: "pinnedFrame").map(NSRectFromString) }
    set { set(newValue.map(NSStringFromRect), forKey: "pinnedFrame") }
  }

  /// Pith registers its login item on its first launch only (spec 4.6 and 12). After that only the
  /// user turns it on or off.
  var loginItemOfferedOnce: Bool {
    get { bool(forKey: "loginItemOfferedOnce") }
    set { set(newValue, forKey: "loginItemOfferedOnce") }
  }
}
