import CMPVShim
import Foundation

public struct MPVOption: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct MPVConfiguration: Equatable, Sendable {
    public var options: [MPVOption]

    public init(options: [MPVOption] = Self.localPlaybackOptions) {
        self.options = options
    }

    /// Predictable application-owned behavior: no user config, terminal UI,
    /// external references, automatic sidecar loading, or mpv keyboard
    /// bindings. Script/front-end features are disabled at compile time in the
    /// pinned MediaCore build, so their unavailable command-line options must
    /// not be passed to libmpv. VideoToolbox is selected by mpv when safe and
    /// software decoding remains available as a fallback.
    public static let localPlaybackOptions: [MPVOption] = [
        MPVOption("config", "no"),
        MPVOption("input-default-bindings", "no"),
        MPVOption("terminal", "no"),
        MPVOption("access-references", "no"),
        MPVOption("autoload-files", "no"),
        MPVOption("idle", "yes"),
        MPVOption("keep-open", "yes"),
        MPVOption("vo", "libmpv"),
        MPVOption("hwdec", "auto-safe"),
    ]
}

public enum MPVCommandResult: Equatable, Sendable {
    case accepted(replyID: UInt64)
    case invalidCommand(MPVCommandMappingError)
    case unavailable(MPVUnavailableReason)
    case rejected(code: Int32, message: String)
}

/// A minimal, thread-safe owner for the dynamically loaded libmpv client.
///
/// Dynamic loading is intentional: `MPVKit` builds before the reproducible
/// universal dependency bundle is placed in `Vendor/MediaCore`, and a missing
/// dylib becomes a normal availability state rather than a launch-time crash.
public final class MPVClient: @unchecked Sendable {
    public let availability: MPVAvailability

    private struct Runtime {
        let library: MPVDynamicLibrary
        let handle: OpaquePointer
        var nextReplyID: UInt64
    }

    private let lock = NSLock()
    private var runtime: Runtime?
    private let renderStateLock = NSLock()
    private var hasRenderContext = false

    public init(
        configuration: MPVConfiguration = MPVConfiguration(),
        librarySearch: MPVLibrarySearch = .bundledAndSystem
    ) {
        do {
            let library = try MPVDynamicLibrary(search: librarySearch)
            guard let handle = library.symbols.create() else {
                availability = .unavailable(.clientCreationFailed)
                return
            }

            for option in configuration.options {
                let result = option.name.withCString { name in
                    option.value.withCString { value in
                        library.symbols.setOptionString(handle, name, value)
                    }
                }
                guard result >= 0 else {
                    library.symbols.terminateDestroy(handle)
                    availability = .unavailable(
                        .optionRejected(name: option.name, code: result)
                    )
                    return
                }
            }

            let result = library.symbols.initialize(handle)
            guard result >= 0 else {
                library.symbols.terminateDestroy(handle)
                availability = .unavailable(.initializationFailed(code: result))
                return
            }

            runtime = Runtime(library: library, handle: handle, nextReplyID: 1)
            availability = .available(
                clientAPIVersion: library.symbols.clientAPIVersion(),
                libraryPath: library.path
            )
        } catch {
            availability = .unavailable(error)
        }
    }

    deinit {
        lock.lock()
        let runtime = self.runtime
        self.runtime = nil
        lock.unlock()
        if let runtime {
            runtime.library.symbols.terminateDestroy(runtime.handle)
        }
    }

    @discardableResult
    public func send(_ command: MPVCommand) -> MPVCommandResult {
        let arguments: [String]
        do {
            arguments = try MPVCommandMapper.arguments(for: command)
        } catch let error as MPVCommandMappingError {
            return .invalidCommand(error)
        } catch {
            return .invalidCommand(.invalidNumber)
        }

        lock.lock()
        guard var runtime else {
            lock.unlock()
            return .unavailable(
                availability.error ?? .clientCreationFailed
            )
        }

        let replyID = runtime.nextReplyID
        runtime.nextReplyID &+= 1
        self.runtime = runtime

        let result = Self.withCStringArray(arguments) { cArguments in
            runtime.library.symbols.commandAsync(
                runtime.handle,
                replyID,
                cArguments
            )
        }
        lock.unlock()

        guard result >= 0 else {
            let message = runtime.library.symbols.errorString(result)
                .map(String.init(cString:)) ?? "libmpv error \(result)"
            return .rejected(code: result, message: message)
        }
        return .accepted(replyID: replyID)
    }

    internal func renderingAccess() -> MPVRenderingAccess? {
        lock.lock()
        defer { lock.unlock() }
        guard let runtime else {
            return nil
        }
        return MPVRenderingAccess(
            clientHandle: runtime.handle,
            symbols: runtime.library.symbols
        )
    }

    internal func setRenderContextAvailable(_ available: Bool) {
        renderStateLock.withLock {
            hasRenderContext = available
        }
    }

    internal func waitForRenderContext(
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            let isReady = renderStateLock.withLock { hasRenderContext }
            if isReady {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }

        return renderStateLock.withLock { hasRenderContext }
    }

    internal func startObservingProperties() {
        guard let access = renderingAccess() else {
            return
        }

        // MPV_FORMAT_NONE asks libmpv to report invalidations without copying
        // values into the event. The event pump then reads a stable string copy.
        let properties = [
            "pause",
            "eof-reached",
            "time-pos",
            "duration",
            "seekable",
            "paused-for-cache",
            "idle-active",
            "video-params",
            "volume",
            "mute",
            "speed",
            "track-list",
            "chapter-list",
        ]
        for (index, property) in properties.enumerated() {
            property.withCString { name in
                _ = access.symbols.observeProperty(
                    access.clientHandle,
                    UInt64(index + 1),
                    name,
                    0
                )
            }
        }
    }

    internal func waitForEvent(timeout: TimeInterval) -> MPVRawEvent {
        guard let access = renderingAccess(),
              let pointer = access.symbols.waitEvent(access.clientHandle, timeout)
        else {
            return .none
        }

        let event = pointer.pointee
        switch event.eventID {
        case 0:
            return .none
        case 1:
            return .shutdown
        case 5:
            return .commandReply(error: event.error, replyID: event.replyUserData)
        case 6:
            guard let data = event.data else {
                return .other(event.eventID)
            }
            let startFile = data.assumingMemoryBound(to: MKVMPVEventStartFile.self).pointee
            return .startFile(entryID: startFile.playlistEntryID)
        case 7:
            guard let data = event.data else {
                return .endFile(reason: -1, error: event.error, entryID: nil)
            }
            let endFile = data.assumingMemoryBound(to: MKVMPVEventEndFilePrefix.self).pointee
            return .endFile(
                reason: endFile.reason,
                error: endFile.error,
                entryID: endFile.playlistEntryID
            )
        case 8:
            return .fileLoaded
        case 9, 10:
            return .tracksChanged
        case 11:
            return .idle
        case 12:
            return .pause
        case 13:
            return .unpause
        case 20:
            return .seek
        case 21:
            return .playbackRestart
        case 22:
            guard let data = event.data else {
                return .none
            }
            let property = data.assumingMemoryBound(to: MKVMPVEventProperty.self).pointee
            return .propertyChanged(property.name.map(String.init(cString:)) ?? "")
        case 23:
            return .chapterChanged
        default:
            return .other(event.eventID)
        }
    }

    internal func wakeup() {
        guard let access = renderingAccess() else {
            return
        }
        access.symbols.wakeup(access.clientHandle)
    }

    internal func stringProperty(_ name: String) -> String? {
        guard let access = renderingAccess() else {
            return nil
        }
        let value = name.withCString { propertyName in
            access.symbols.getPropertyString(access.clientHandle, propertyName)
        }
        guard let value else {
            return nil
        }
        defer { access.symbols.free(UnsafeMutableRawPointer(value)) }
        return String(cString: value)
    }

    internal func integerProperty(_ name: String) -> Int64? {
        stringProperty(name).flatMap(Int64.init)
    }

    internal func doubleProperty(_ name: String) -> Double? {
        stringProperty(name).flatMap(Double.init)
    }

    internal func boolProperty(_ name: String) -> Bool? {
        switch stringProperty(name)?.lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }

    internal func errorMessage(for code: Int32) -> String {
        guard let access = renderingAccess(),
              let message = access.symbols.errorString(code)
        else {
            return "libmpv error \(code)"
        }
        return String(cString: message)
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafePointer<UnsafePointer<CChar>?>?) -> Result
    ) -> Result {
        let storage = strings.map { strdup($0) }
        defer {
            for pointer in storage {
                free(pointer)
            }
        }

        var arguments: [UnsafePointer<CChar>?] = storage.map { pointer in
            guard let pointer else {
                return nil
            }
            return UnsafePointer<CChar>(pointer)
        }
        arguments.append(nil)
        return arguments.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }
}

internal struct MPVRenderingAccess: @unchecked Sendable {
    let clientHandle: OpaquePointer
    let symbols: MPVSymbols
}

internal enum MPVRawEvent: Equatable, Sendable {
    case none
    case shutdown
    case commandReply(error: Int32, replyID: UInt64)
    case startFile(entryID: Int64)
    case endFile(reason: Int32, error: Int32, entryID: Int64?)
    case fileLoaded
    case tracksChanged
    case idle
    case pause
    case unpause
    case seek
    case playbackRestart
    case propertyChanged(String)
    case chapterChanged
    case other(Int32)
}
