import CMPVShim
import Darwin
import Foundation

public enum MPVLibrarySearch: Equatable, Sendable {
    /// Searches an explicit environment override, the app's Frameworks folder,
    /// and finally the dynamic loader's normal paths.
    case bundledAndSystem

    /// Searches exactly these paths, in order. Useful for development and tests.
    case paths([String])

    /// Never attempts to load libmpv. This provides a deterministic fallback
    /// state for previews, tests, and builds made before dependencies are vendored.
    case disabled(reason: String)
}

public enum MPVUnavailableReason: Error, Equatable, Sendable {
    case disabled(String)
    case libraryNotFound(searched: [String])
    case missingSymbol(String)
    case clientCreationFailed
    case optionRejected(name: String, code: Int32)
    case initializationFailed(code: Int32)
}

public enum MPVAvailability: Equatable, Sendable {
    case available(clientAPIVersion: UInt64, libraryPath: String)
    case unavailable(MPVUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    public var error: MPVUnavailableReason? {
        guard case let .unavailable(error) = self else {
            return nil
        }
        return error
    }
}

internal final class MPVDynamicLibrary: @unchecked Sendable {
    let path: String
    let symbols: MPVSymbols

    private let handle: UnsafeMutableRawPointer

    init(search: MPVLibrarySearch) throws(MPVUnavailableReason) {
        let candidates: [String]
        switch search {
        case let .disabled(reason):
            throw .disabled(reason)
        case let .paths(paths):
            candidates = paths
        case .bundledAndSystem:
            candidates = Self.defaultCandidates()
        }

        var loaded: (handle: UnsafeMutableRawPointer, path: String)?
        for candidate in candidates {
            if let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) {
                loaded = (handle, candidate)
                break
            }
        }

        guard let loaded else {
            throw .libraryNotFound(searched: candidates)
        }

        do {
            let symbols = try MPVSymbols(handle: loaded.handle)
            self.handle = loaded.handle
            path = loaded.path
            self.symbols = symbols
        } catch let error as MPVSymbolError {
            dlclose(loaded.handle)
            throw .missingSymbol(error.name)
        } catch {
            dlclose(loaded.handle)
            throw .missingSymbol("unknown")
        }
    }

    deinit {
        dlclose(handle)
    }

    private static func defaultCandidates() -> [String] {
        var result: [String] = []

        if let frameworks = Bundle.main.privateFrameworksURL {
            result.append(
                frameworks
                    .appendingPathComponent("MediaCore.framework")
                    .appendingPathComponent("MediaCore")
                    .path
            )
            result.append(frameworks.appendingPathComponent("libmpv.2.dylib").path)
            result.append(frameworks.appendingPathComponent("libmpv.dylib").path)
        }

#if DEBUG
        // Development-only fallbacks. Shipped builds resolve the signed copy in
        // Contents/Frameworks first, so a user's Homebrew installation can never
        // override the reproducible application bundle.
        if let override = ProcessInfo.processInfo.environment["MKV_PLAYER_LIBMPV_PATH"],
           !override.isEmpty
        {
            result.append(override)
        }
        result.append("/opt/homebrew/lib/libmpv.2.dylib")
        result.append("/opt/homebrew/lib/libmpv.dylib")
        result.append("/usr/local/lib/libmpv.2.dylib")
        result.append("/usr/local/lib/libmpv.dylib")
        result.append("libmpv.2.dylib")
        result.append("libmpv.dylib")
#endif
        return result
    }
}

private struct MPVSymbolError: Error {
    let name: String
}

internal final class MPVSymbols: @unchecked Sendable {
    typealias Create = @convention(c) () -> OpaquePointer?
    typealias Initialize = @convention(c) (OpaquePointer?) -> Int32
    typealias TerminateDestroy = @convention(c) (OpaquePointer?) -> Void
    typealias SetOptionString = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Int32
    typealias CommandAsync = @convention(c) (
        OpaquePointer?,
        UInt64,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    typealias ClientAPIVersion = @convention(c) () -> UInt64
    typealias ErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?
    typealias ObserveProperty = @convention(c) (
        OpaquePointer?,
        UInt64,
        UnsafePointer<CChar>?,
        Int32
    ) -> Int32
    typealias GetPropertyString = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>?
    typealias WaitEvent = @convention(c) (
        OpaquePointer?,
        Double
    ) -> UnsafePointer<MKVMPVEvent>?
    typealias Wakeup = @convention(c) (OpaquePointer?) -> Void
    typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void

    typealias RenderContextCreate = @convention(c) (
        UnsafeMutablePointer<OpaquePointer?>?,
        OpaquePointer?,
        UnsafeMutablePointer<MKVMPVRenderParam>?
    ) -> Int32
    typealias RenderContextSetUpdateCallback = @convention(c) (
        OpaquePointer?,
        (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
        UnsafeMutableRawPointer?
    ) -> Void
    typealias RenderContextRender = @convention(c) (
        OpaquePointer?,
        UnsafeMutablePointer<MKVMPVRenderParam>?
    ) -> Int32
    typealias RenderContextReportSwap = @convention(c) (OpaquePointer?) -> Void
    typealias RenderContextFree = @convention(c) (OpaquePointer?) -> Void

    let create: Create
    let initialize: Initialize
    let terminateDestroy: TerminateDestroy
    let setOptionString: SetOptionString
    let commandAsync: CommandAsync
    let clientAPIVersion: ClientAPIVersion
    let errorString: ErrorString
    let observeProperty: ObserveProperty
    let getPropertyString: GetPropertyString
    let waitEvent: WaitEvent
    let wakeup: Wakeup
    let free: Free
    let renderContextCreate: RenderContextCreate
    let renderContextSetUpdateCallback: RenderContextSetUpdateCallback
    let renderContextRender: RenderContextRender
    let renderContextReportSwap: RenderContextReportSwap
    let renderContextFree: RenderContextFree

    init(handle: UnsafeMutableRawPointer) throws {
        create = try Self.load("mpv_create", from: handle)
        initialize = try Self.load("mpv_initialize", from: handle)
        terminateDestroy = try Self.load("mpv_terminate_destroy", from: handle)
        setOptionString = try Self.load("mpv_set_option_string", from: handle)
        commandAsync = try Self.load("mpv_command_async", from: handle)
        clientAPIVersion = try Self.load("mpv_client_api_version", from: handle)
        errorString = try Self.load("mpv_error_string", from: handle)
        observeProperty = try Self.load("mpv_observe_property", from: handle)
        getPropertyString = try Self.load("mpv_get_property_string", from: handle)
        waitEvent = try Self.load("mpv_wait_event", from: handle)
        wakeup = try Self.load("mpv_wakeup", from: handle)
        free = try Self.load("mpv_free", from: handle)
        renderContextCreate = try Self.load("mpv_render_context_create", from: handle)
        renderContextSetUpdateCallback = try Self.load(
            "mpv_render_context_set_update_callback",
            from: handle
        )
        renderContextRender = try Self.load("mpv_render_context_render", from: handle)
        renderContextReportSwap = try Self.load(
            "mpv_render_context_report_swap",
            from: handle
        )
        renderContextFree = try Self.load("mpv_render_context_free", from: handle)
    }

    private static func load<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let address = dlsym(handle, name) else {
            throw MPVSymbolError(name: name)
        }
        return unsafeBitCast(address, to: T.self)
    }
}

internal enum MPVRenderParameter: Int32 {
    case invalid = 0
    case apiType = 1
    case openGLInitParams = 2
    case openGLFBO = 3
    case flipY = 4
    case softwareSize = 17
    case softwareFormat = 18
    case softwareStride = 19
    case softwarePointer = 20
}
