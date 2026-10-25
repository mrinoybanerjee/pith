import PithCore
import SwiftUI

/// The three settings (spec 4.6). The login toggle shows what macOS really does, and says so when
/// macOS refuses a change (R59). Limited grouping is a visible degraded mode (spec 6.5).
struct SettingsView: View {
  @Bindable var store: Store

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          label("Launch at login")
          Toggle(
            "Launch at login",
            isOn: Binding(get: { store.launchesAtLogin }, set: { store.setLaunchAtLogin($0) })
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .labelsHidden()
        }
        if store.loginItemFailed {
          Text("Couldn't change this. Try again in System Settings → General → Login Items.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        HStack {
          Text("Refresh while open").frame(maxWidth: .infinity, alignment: .leading)
          Segmented(
            selection: $store.settings.refresh,
            options: [(.oneSecond, "1 s"), (.twoSeconds, "2 s")])
        }
        Divider()
        label("Dot turns amber on")
        Picker("Dot turns amber on", selection: $store.settings.amberOnCPU) {
          Text("Memory, CPU or storage").tag(true)
          Text("Memory or storage only").tag(false)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
      }
      .padding(12)
      .background(.quinary, in: .rect(cornerRadius: 10))
      if store.snapshot?.grouping == .limited {
        Text("App grouping is limited on this macOS version.")
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      }
    }
    .font(.system(size: 13))
    .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
  }

  /// The visible name of a native control. VoiceOver reads it from the control instead.
  private func label(_ text: String) -> some View {
    Text(text)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityHidden(true)
  }
}
