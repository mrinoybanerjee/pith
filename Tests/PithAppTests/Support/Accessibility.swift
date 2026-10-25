import AppKit
import Testing

/// One element of a window's accessibility tree, read as VoiceOver reads it.
@MainActor struct AXNode {
  /// Points of a 13 pt system font's line, to tell a heading's font size from its height.
  private static let lineHeightPerPoint =
    NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13)) / 13

  let element: NSObject
  let role: String
  let label: String?
  let value: String?
  let identifier: String?
  let selected: Bool
  /// In screen coordinates.
  let frame: CGRect
  /// The point sizes of the text runs. SwiftUI reports none for a heading, so a one-line heading's
  /// size comes from its height; a button reports none, so a button with text keeps it as a child.
  let fontSizes: [CGFloat]
  let children: [AXNode]

  /// What VoiceOver speaks. It reads a no-break space as a space.
  var spoken: String? { (label ?? value)?.replacing("\u{A0}", with: " ") }
  var flattened: [AXNode] { [self] + children.flatMap(\.flattened) }

  /// SwiftUI's elements answer the NSAccessibility selectors without declaring the protocol, so
  /// the walk sends the selectors, as AppKit does.
  init(_ element: NSObject) {
    func object(_ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }
    func text(_ value: Any?) -> String? {
      switch value {
      case let string as String: string
      case let number as NSNumber: number.stringValue
      default: nil
      }
    }
    self.element = element
    role = object("accessibilityRole") as? String ?? "AXUnknown"
    label = (object("accessibilityLabel") as? String).flatMap { $0.isEmpty ? nil : $0 }
    value = text(object("accessibilityValue"))
    identifier = object("accessibilityIdentifier") as? String
    selected = Self.call(element, "isAccessibilitySelected", as: Bool.self) ?? false
    frame = Self.call(element, "accessibilityFrame", as: CGRect.self) ?? .zero
    fontSizes =
      role == "AXHeading"
      ? [frame.height / Self.lineHeightPerPoint] : Self.fontSizes(element, of: value ?? label)
    children = (object("accessibilityChildren") as? [NSObject] ?? []).map(AXNode.init)
  }

  private static func fontSizes(_ element: NSObject, of text: String?) -> [CGFloat] {
    let selector = NSSelectorFromString("accessibilityAttributedStringForRange:")
    guard let text, let method = class_getInstanceMethod(type(of: element), selector) else {
      return []
    }
    typealias Getter = @convention(c) (AnyObject, Selector, NSRange) -> NSAttributedString?
    guard
      let string = unsafeBitCast(method_getImplementation(method), to: Getter.self)(
        element, selector, NSRange(location: 0, length: (text as NSString).length))
    else { return [] }
    var sizes: [CGFloat] = []
    string.enumerateAttribute(
      NSAttributedString.Key("AXFont"), in: NSRange(location: 0, length: string.length)
    ) { font, _, _ in
      if let size = (font as? [String: Any])?["AXFontSize"] as? NSNumber {
        sizes.append(CGFloat(size.doubleValue))
      }
    }
    return sizes
  }

  private static func call(_ element: NSObject, _ name: String, as _: Bool.Type) -> Bool? {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(type(of: element), selector) else { return nil }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(method_getImplementation(method), to: Getter.self)(element, selector)
  }

  private static func call(_ element: NSObject, _ name: String, as _: CGRect.Type) -> CGRect? {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(type(of: element), selector) else { return nil }
    typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
    return unsafeBitCast(method_getImplementation(method), to: Getter.self)(element, selector)
  }

  /// Presses the element, as VoiceOver's VO-Space does.
  func press() {
    #expect(Self.call(element, "accessibilityPerformPress", as: Bool.self) == true)
  }
}

private let interactiveRoles: Set<String> = [
  "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
  "AXDisclosureTriangle", "AXLink", "AXSwitch",
]

@MainActor func axNodes(in window: NSWindow) -> [AXNode] { AXNode(window).flattened }

/// Everything VoiceOver speaks in `window`.
@MainActor func axLabels(in window: NSWindow) -> [String] {
  axNodes(in: window).compactMap(\.spoken)
}

@MainActor func axInteractiveElements(in window: NSWindow) -> [AXNode] {
  axNodes(in: window).filter { interactiveRoles.contains($0.role) }
}

@MainActor func axNode(_ spoken: String, in window: NSWindow) throws -> AXNode {
  try #require(axNodes(in: window).first { $0.spoken == spoken }, "no element \"\(spoken)\"")
}

@MainActor func press(_ label: String, in window: NSWindow) throws {
  try #require(axInteractiveElements(in: window).first { $0.label == label }).press()
}

/// The smallest font of any text VoiceOver can read in `window`, leaving out the element with
/// `identifier` and everything inside it.
@MainActor func minimumReadableFontSize(_ window: NSWindow, excludingIdentifier identifier: String)
  -> CGFloat
{
  func sizes(_ node: AXNode) -> [CGFloat] {
    node.identifier == identifier ? [] : node.fontSizes + node.children.flatMap(sizes)
  }
  let all = sizes(AXNode(window))
  #expect(all.count > 10, "found \(all.count) text runs")
  return all.min() ?? 0
}

/// The frames of the rows' values and process counts, in the window's coordinates.
@MainActor func valueColumnFrames(in window: NSWindow) -> [CGRect] {
  let frames = axNodes(in: window).filter { $0.identifier == "pith.value" }.map {
    window.convertFromScreen($0.frame)
  }
  #expect(frames.count >= 5, "found \(frames.count) values")
  return frames
}
