import CMPVShim
import Foundation

private final class MPVOffscreenRenderUpdateContext: @unchecked Sendable {
    weak var surface: MPVOffscreenRenderSurface?

    init(surface: MPVOffscreenRenderSurface) {
        self.surface = surface
    }
}

private let mpvOffscreenRenderUpdate: @convention(c) (
    UnsafeMutableRawPointer?
) -> Void = { context in
    guard let context else {
        return
    }
    let updateContext = Unmanaged<MPVOffscreenRenderUpdateContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    updateContext.surface?.scheduleFrame()
}

/// A small software-rendered surface for noninteractive integration hosts.
///
/// GitHub-hosted macOS runners do not guarantee that Core Animation can
/// allocate an on-screen OpenGL drawable. This SPI keeps release tests on
/// libmpv's supported render API and consumes real decoded frames without
/// making a window server or GPU part of the test contract. Production uses
/// ``MPVVideoSurface`` and its hardware-accelerated AppKit presentation path.
@_spi(Testing)
public final class MPVOffscreenRenderSurface: @unchecked Sendable {
    private static let width: Int32 = 16
    private static let height: Int32 = 16
    private static let bytesPerPixel = 4

    private let client: MPVClient
    private let access: MPVRenderingAccess
    private let renderQueue = DispatchQueue(
        label: "io.github.youssefsz.MKVPlayer.offscreen-render",
        qos: .userInitiated
    )
    private let renderQueueKey = DispatchSpecificKey<UInt8>()
    private let lifecycleLock = NSLock()
    private let pixelBuffer: UnsafeMutableRawPointer
    private var renderContext: OpaquePointer?
    private var updateContext: Unmanaged<MPVOffscreenRenderUpdateContext>?
    private var isStopping = false
    private var isFrameScheduled = false

    @_spi(Testing)
    public convenience init?(engine: MPVEngine) {
        self.init(client: engine.client)
    }

    private init?(client: MPVClient) {
        guard let access = client.renderingAccess(),
              MemoryLayout<MKVMPVRenderParam>.size == 16
        else {
            return nil
        }

        let byteCount = Int(Self.width * Self.height) * Self.bytesPerPixel
        let pixelBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 64
        )
        pixelBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        self.client = client
        self.access = access
        self.pixelBuffer = pixelBuffer
        renderQueue.setSpecific(key: renderQueueKey, value: 1)

        var api = Array("sw".utf8CString)
        var createdContext: OpaquePointer?
        let result = api.withUnsafeMutableBufferPointer { apiBuffer in
            var parameters = [
                MKVMPVRenderParam(
                    type: MPVRenderParameter.apiType.rawValue,
                    data: UnsafeMutableRawPointer(apiBuffer.baseAddress)
                ),
                MKVMPVRenderParam(
                    type: MPVRenderParameter.invalid.rawValue,
                    data: nil
                ),
            ]
            return parameters.withUnsafeMutableBufferPointer { buffer in
                access.symbols.renderContextCreate(
                    &createdContext,
                    access.clientHandle,
                    buffer.baseAddress
                )
            }
        }

        guard result >= 0, let createdContext else {
            pixelBuffer.deallocate()
            return nil
        }

        renderContext = createdContext
        let retainedContext = Unmanaged.passRetained(
            MPVOffscreenRenderUpdateContext(surface: self)
        )
        updateContext = retainedContext
        access.symbols.renderContextSetUpdateCallback(
            createdContext,
            mpvOffscreenRenderUpdate,
            retainedContext.toOpaque()
        )
        client.setRenderContextAvailable(true)
    }

    deinit {
        lifecycleLock.lock()
        isStopping = true
        let renderContext = self.renderContext
        lifecycleLock.unlock()

        if let renderContext {
            access.symbols.renderContextSetUpdateCallback(renderContext, nil, nil)
        }
        if DispatchQueue.getSpecific(key: renderQueueKey) == nil {
            renderQueue.sync {}
        }
        if let renderContext {
            access.symbols.renderContextFree(renderContext)
        }
        self.renderContext = nil
        client.setRenderContextAvailable(false)
        updateContext?.release()
        updateContext = nil
        pixelBuffer.deallocate()
    }

    fileprivate func scheduleFrame() {
        lifecycleLock.lock()
        let shouldSchedule = !isStopping
            && renderContext != nil
            && !isFrameScheduled
        if shouldSchedule {
            isFrameScheduled = true
        }
        lifecycleLock.unlock()
        guard shouldSchedule else {
            return
        }

        renderQueue.async { [weak self] in
            self?.renderFrame()
        }
    }

    private func renderFrame() {
        lifecycleLock.lock()
        // One queued render is enough: libmpv always draws the newest frame.
        // Clearing this before rendering lets an update that arrives during
        // the call enqueue exactly one follow-up without growing the queue.
        isFrameScheduled = false
        let renderContext = isStopping ? nil : self.renderContext
        lifecycleLock.unlock()
        guard let renderContext else {
            return
        }

        var size = [Self.width, Self.height]
        var format = Array("rgb0".utf8CString)
        var stride = Int(Self.width) * Self.bytesPerPixel

        size.withUnsafeMutableBufferPointer { sizeBuffer in
            format.withUnsafeMutableBufferPointer { formatBuffer in
                withUnsafeMutablePointer(to: &stride) { stridePointer in
                    var parameters = [
                        MKVMPVRenderParam(
                            type: MPVRenderParameter.softwareSize.rawValue,
                            data: UnsafeMutableRawPointer(sizeBuffer.baseAddress)
                        ),
                        MKVMPVRenderParam(
                            type: MPVRenderParameter.softwareFormat.rawValue,
                            data: UnsafeMutableRawPointer(formatBuffer.baseAddress)
                        ),
                        MKVMPVRenderParam(
                            type: MPVRenderParameter.softwareStride.rawValue,
                            data: UnsafeMutableRawPointer(stridePointer)
                        ),
                        MKVMPVRenderParam(
                            type: MPVRenderParameter.softwarePointer.rawValue,
                            data: pixelBuffer
                        ),
                        MKVMPVRenderParam(
                            type: MPVRenderParameter.invalid.rawValue,
                            data: nil
                        ),
                    ]
                    parameters.withUnsafeMutableBufferPointer { buffer in
                        _ = access.symbols.renderContextRender(
                            renderContext,
                            buffer.baseAddress
                        )
                    }
                }
            }
        }
    }
}
