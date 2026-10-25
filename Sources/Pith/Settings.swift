import Foundation
import PithCore
import ServiceManagement
import os

/// The three settings (spec 4.6). A key that was never saved has its default; a saved value of the
/// wrong type traps.
struct Settings: Equatable {
  var launchAtLogin = true
  var refresh = RefreshSetting.oneSecond
  var amberOnCPU = true

  static func load(_ defaults: UserDefaults) -> Settings {
    var settings = Settings()
    if let value = defaults.object(forKey: "launchAtLogin") {
      settings.launchAtLogin = value as! Bool
    }
    if let value = defaults.object(forKey: "refresh") {
      settings.refresh = RefreshSetting(rawValue: value as! String)!
    }
    if let value = defaults.object(forKey: "amberOnCPU") { settings.amberOnCPU = value as! Bool }
    return settings
  }

  func save(_ defaults: UserDefaults) {
    defaults.set(launchAtLogin, forKey: "launchAtLogin")
    defaults.set(refresh.rawValue, forKey: "refresh")
    defaults.set(amberOnCPU, forKey: "amberOnCPU")
  }

  /// Registers Pith as a login item, or removes it, to follow `launchAtLogin`. macOS can refuse, for
  /// example for an app outside a bundle; the refusal is logged as an error.
  static func setLoginItem(_ enabled: Bool) {
    let app = SMAppService.mainApp
    do {
      if enabled, app.status != .enabled { try app.register() }
      if !enabled, app.status != .notRegistered { try app.unregister() }
    } catch {
      Logger(subsystem: "com.mrinoy.pith", category: "login-item")
        .error("cannot set launch at login to \(enabled): \(error, privacy: .public)")
    }
  }
}

extension UserDefaults {
  /// The pinned panel's frame (spec 4.7). It is saved apart from the settings because every drag
  /// changes it.
  var pinnedFrame: CGRect? {
    get { string(forKey: "pinnedFrame").map(NSRectFromString) }
    set { set(newValue.map(NSStringFromRect), forKey: "pinnedFrame") }
  }
}
