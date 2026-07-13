import Combine
import Sparkle

/// Keeps the Settings toggle connected to Sparkle's live scheduler instead of
/// treating Sparkle's persisted preference as an ordinary user default.
@MainActor
final class UpdateSettingsModel: ObservableObject {
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            updateHandler(automaticallyChecksForUpdates)
        }
    }

    private let updateHandler: @MainActor (Bool) -> Void

    convenience init(updater: SPUUpdater) {
        self.init(
            initialValue: updater.automaticallyChecksForUpdates,
            updateHandler: { updater.automaticallyChecksForUpdates = $0 }
        )
    }

    init(initialValue: Bool, updateHandler: @escaping @MainActor (Bool) -> Void) {
        automaticallyChecksForUpdates = initialValue
        self.updateHandler = updateHandler
    }
}
