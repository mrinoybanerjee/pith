// Renders Resources/AppIcon.icns from code: the calm dot, an outline ring, on a soft neutral
// squircle. An .icns cannot follow the system appearance, so there is one light icon.
// Usage, from the repository root: swift scripts/make-app-icon.swift   (then commit the .icns)
import AppKit
import SwiftUI

/// The light panel's ink (spec mockup `--ink`).
let ink = Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255)

/// macOS icon grid: an 824-point continuous rounded square centred in 1024, with shadow. The ring
/// keeps the menu-bar dot's proportions: a 1.6-point line on a 9-point circle.
struct Icon: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 185, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color(white: 0.99), Color(white: 0.89)], startPoint: .top, endPoint: .bottom)
        )
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
      Circle().strokeBorder(ink, lineWidth: 400 * 1.6 / 9).frame(width: 400, height: 400)
    }
    .frame(width: 1024, height: 1024)
  }
}

@MainActor func png(pixels: Int) -> Data {
  let renderer = ImageRenderer(content: Icon())
  renderer.scale = CGFloat(pixels) / 1024
  let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
  return rep.representation(using: .png, properties: [:])!
}

@MainActor func run() throws {
  let resources = URL(fileURLWithPath: "Resources", isDirectory: true)
  guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("Info.plist").path)
  else {
    print("Run from the repository root.")
    exit(1)
  }
  let iconset = URL(fileURLWithPath: ".build/AppIcon.iconset", isDirectory: true)
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: iconset) }
  for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(
      to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(
      to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
  }
  let iconutil = Process()
  iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  iconutil.arguments = [
    "-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path,
  ]
  try iconutil.run()
  iconutil.waitUntilExit()
  guard iconutil.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
  print("Wrote Resources/AppIcon.icns")
}

try MainActor.assumeIsolated { try run() }
