import Foundation

enum PreferenceKey {
    static let resumePlayback = "resumePlayback"
    static let autoplay = "autoplay"
}

@MainActor
struct PlayerPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            PreferenceKey.resumePlayback: true,
            PreferenceKey.autoplay: true
        ])
    }

    var resumesPlayback: Bool { defaults.bool(forKey: PreferenceKey.resumePlayback) }
    var autoplays: Bool { defaults.bool(forKey: PreferenceKey.autoplay) }
}
