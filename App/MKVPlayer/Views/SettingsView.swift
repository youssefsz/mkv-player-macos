import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKey.resumePlayback) private var resumePlayback = true
    @AppStorage(PreferenceKey.autoplay) private var autoplay = true
    @ObservedObject var updateSettings: UpdateSettingsModel

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Resume videos where I stopped", isOn: $resumePlayback)
                Toggle("Play automatically after opening", isOn: $autoplay)
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: $updateSettings.automaticallyChecksForUpdates
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
    }
}
