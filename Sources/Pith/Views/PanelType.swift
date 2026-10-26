import SwiftUI

/// The panel's type sizes, all in one place (spec 4.2): SF Pro, 13 pt or more for anything the user
/// must read. Only the decorative footer is smaller.
enum PanelType: CGFloat, CaseIterable {
  case title = 17
  case value = 19
  case body = 13
  case footer = 11.5
}

extension Font {
  static func panel(_ type: PanelType, weight: Font.Weight = .regular) -> Font {
    .system(size: type.rawValue, weight: weight)
  }
}
