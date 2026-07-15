import AppKit
import CMPVShim
import CoreFoundation
import CoreVideo
import OpenGL.GL3
import QuartzCore

public enum MPVVideoSurfaceState: Equatable, Sendable {
    case ready
    case unavailable(MPVUnavailableReason)
}

/// AppKit host view for libmpv's official render API.
///
/// libmpv currently exposes OpenGL and software render APIs. The deprecated
/// OpenGL dependency is intentionally contained in this one replaceable type.
@MainActor
public final class MPVVideoSurface: NSView {
    public let state: MPVVideoSurfaceState

    private let client: MPVClient
    private let videoLayer: CALayer

    public init(client: MPVClient) {
        self.client = client

        if client.availability.isAvailable {
            state = .ready
            videoLayer = MPVOpenGLLayer(client: client)
        } else {
            let fallback = CALayer()
            fallback.backgroundColor = NSColor.black.cgColor
            state = .unavailable(
                client.availability.error ?? .clientCreationFailed
            )
            videoLayer = fallback
        }

        super.init(frame: .zero)
        wantsLayer = true
        layer = videoLayer
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video")
    }

    public convenience init(engine: MPVEngine) {
        self.init(client: engine.client)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isOpaque: Bool {
        true
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    public var allowsExtendedDynamicRange: Bool {
        get { (videoLayer as? MPVOpenGLLayer)?.wantsExtendedDynamicRangeContent ?? false }
        set { (videoLayer as? MPVOpenGLLayer)?.wantsExtendedDynamicRangeContent = newValue }
    }

    /// Waits until Core Animation has created libmpv's render context.
    ///
    /// `state` reports whether libmpv was loaded successfully. A hosted layer
    /// still needs a drawable before playback can start, which may take longer
    /// when a window is first presented on a busy or virtualized Mac.
    public func waitUntilReadyForPlayback(
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        guard state == .ready else {
            return false
        }
        videoLayer.setNeedsDisplay()
        return await client.waitForRenderContext(timeout: timeout)
    }

    private func updateContentsScale() {
        videoLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        videoLayer.setNeedsDisplay()
    }
}

private final class MPVRenderUpdateContext: @unchecked Sendable {
    weak var layer: MPVOpenGLLayer?

    init(layer: MPVOpenGLLayer) {
        self.layer = layer
    }
}

private let mpvGetOpenGLProcAddress: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? = { _, name in
    guard let name,
          let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
    else {
        return nil
    }

    return CFBundleGetFunctionPointerForName(
        bundle,
        String(cString: name) as CFString
    )
}

private let mpvRenderUpdate: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else {
        return
    }
    let updateContext = Unmanaged<MPVRenderUpdateContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    guard let layer = updateContext.layer else {
        return
    }
    DispatchQueue.main.async { [weak layer] in
        layer?.setNeedsDisplay()
    }
}

private final class MPVOpenGLLayer: CAOpenGLLayer, @unchecked Sendable {
    private let client: MPVClient
    private let renderLock = NSLock()
    private var renderContext: OpaquePointer?
    private var renderCGLContext: CGLContextObj?
    private var updateContext: Unmanaged<MPVRenderUpdateContext>?

    init(client: MPVClient) {
        self.client = client
        super.init()
        isAsynchronous = false
        isOpaque = true
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override init(layer: Any) {
        guard let source = layer as? MPVOpenGLLayer else {
            fatalError("Unexpected layer copy")
        }
        client = source.client
        super.init(layer: layer)
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
    }

    deinit {
        renderLock.lock()
        tearDownRenderContextLocked(using: renderCGLContext)
        renderLock.unlock()
    }

    override func canDraw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        client.availability.isAvailable
    }

    override func draw(
        inCGLContext context: CGLContextObj,
        pixelFormat: CGLPixelFormatObj,
        forLayerTime layerTime: CFTimeInterval,
        displayTime: UnsafePointer<CVTimeStamp>?
    ) {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard prepareRenderContextIfNeeded(cglContext: context),
              let renderContext,
              let access = client.renderingAccess()
        else {
            super.draw(
                inCGLContext: context,
                pixelFormat: pixelFormat,
                forLayerTime: layerTime,
                displayTime: displayTime
            )
            return
        }

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)

        let scale = max(contentsScale, 1)
        var fbo = MKVMPVOpenGLFBO(
            fbo: framebuffer,
            width: Int32(max(1, (bounds.width * scale).rounded(.up))),
            height: Int32(max(1, (bounds.height * scale).rounded(.up))),
            internalFormat: 0
        )
        var flipY: Int32 = 1

        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                var parameters = [
                    MKVMPVRenderParam(
                        type: MPVRenderParameter.openGLFBO.rawValue,
                        data: UnsafeMutableRawPointer(fboPointer)
                    ),
                    MKVMPVRenderParam(
                        type: MPVRenderParameter.flipY.rawValue,
                        data: UnsafeMutableRawPointer(flipPointer)
                    ),
                    MKVMPVRenderParam(type: MPVRenderParameter.invalid.rawValue, data: nil),
                ]

                parameters.withUnsafeMutableBufferPointer { buffer in
                    _ = access.symbols.renderContextRender(renderContext, buffer.baseAddress)
                }
            }
        }

        // CAOpenGLLayer documents that its superclass implementation flushes
        // the drawable and should be called after custom rendering. It does not
        // redraw or clear the framebuffer.
        super.draw(
            inCGLContext: context,
            pixelFormat: pixelFormat,
            forLayerTime: layerTime,
            displayTime: displayTime
        )
        access.symbols.renderContextReportSwap(renderContext)
    }

    override func releaseCGLContext(_ context: CGLContextObj) {
        renderLock.lock()
        if renderCGLContext == context {
            tearDownRenderContextLocked(using: context)
        }
        renderLock.unlock()
        super.releaseCGLContext(context)
    }

    private func prepareRenderContextIfNeeded(cglContext: CGLContextObj) -> Bool {
        if renderContext != nil, renderCGLContext == cglContext {
            return true
        }
        if let previousContext = renderCGLContext {
            tearDownRenderContextLocked(using: previousContext)
        }
        guard let access = client.renderingAccess() else {
            return false
        }

        // mpv 0.41's public C layouts are stable on both 64-bit macOS
        // architectures. Refuse to cross the ABI if Swift ever changes these
        // local mirror layouts.
        guard MemoryLayout<MKVMPVRenderParam>.size == 16,
              MemoryLayout<MKVMPVOpenGLInitParams>.size == 16,
              MemoryLayout<MKVMPVOpenGLFBO>.size == 16
        else {
            return false
        }

        var api = Array("opengl".utf8CString)
        var openGLParameters = MKVMPVOpenGLInitParams(
            getProcAddress: mpvGetOpenGLProcAddress,
            context: nil
        )
        var createdContext: OpaquePointer?

        let result = api.withUnsafeMutableBufferPointer { apiBuffer in
            withUnsafeMutablePointer(to: &openGLParameters) { openGLPointer in
                // Advanced control is intentionally omitted. In default mode an
                // update callback directly means a frame should be scheduled.
                // Advanced mode would additionally require calling
                // mpv_render_context_update and inspecting MPV_RENDER_UPDATE_FRAME.
                var parameters = [
                    MKVMPVRenderParam(
                        type: MPVRenderParameter.apiType.rawValue,
                        data: UnsafeMutableRawPointer(apiBuffer.baseAddress)
                    ),
                    MKVMPVRenderParam(
                        type: MPVRenderParameter.openGLInitParams.rawValue,
                        data: UnsafeMutableRawPointer(openGLPointer)
                    ),
                    MKVMPVRenderParam(type: MPVRenderParameter.invalid.rawValue, data: nil),
                ]
                return parameters.withUnsafeMutableBufferPointer { buffer in
                    access.symbols.renderContextCreate(
                        &createdContext,
                        access.clientHandle,
                        buffer.baseAddress
                    )
                }
            }
        }

        guard result >= 0, let createdContext else {
            return false
        }

        renderContext = createdContext
        renderCGLContext = cglContext
        let retainedContext = Unmanaged.passRetained(MPVRenderUpdateContext(layer: self))
        updateContext = retainedContext
        access.symbols.renderContextSetUpdateCallback(
            createdContext,
            mpvRenderUpdate,
            retainedContext.toOpaque()
        )
        client.setRenderContextAvailable(true)
        return true
    }

    private func tearDownRenderContextLocked(using cglContext: CGLContextObj?) {
        client.setRenderContextAvailable(false)
        guard let renderContext else {
            updateContext?.release()
            updateContext = nil
            renderCGLContext = nil
            return
        }

        guard let access = client.renderingAccess(), let cglContext else {
            // The client and CGL context both outlive a correctly hosted layer.
            // If that invariant is broken, leaking is safer than invoking the
            // render API without its required current context.
            return
        }

        let previousContext = CGLGetCurrentContext()
        let switchedContext = previousContext != cglContext
        if switchedContext {
            CGLLockContext(cglContext)
            CGLSetCurrentContext(cglContext)
        }

        access.symbols.renderContextSetUpdateCallback(renderContext, nil, nil)
        access.symbols.renderContextFree(renderContext)
        self.renderContext = nil
        renderCGLContext = nil
        updateContext?.release()
        updateContext = nil

        if switchedContext {
            CGLSetCurrentContext(previousContext)
            CGLUnlockContext(cglContext)
        }
    }
}
