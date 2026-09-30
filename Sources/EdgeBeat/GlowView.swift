import AppKit
import Combine
import Metal
import OSLog
import QuartzCore

struct DisplayNotch: Equatable {
    let minX: CGFloat
    let maxX: CGFloat
    let depth: CGFloat
    let cornerRadius: CGFloat

    init?(screen: NSScreen) {
        guard screen.safeAreaInsets.top > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return nil }

        let minX = leftArea.maxX - screen.frame.minX
        let maxX = rightArea.minX - screen.frame.minX
        guard maxX > minX else { return nil }

        depth = screen.safeAreaInsets.top
        self.minX = minX
        self.maxX = maxX
        cornerRadius = min(10, depth * 0.32, (maxX - minX) * 0.12)
    }

    init(minX: CGFloat, maxX: CGFloat, depth: CGFloat, cornerRadius: CGFloat) {
        self.minX = minX
        self.maxX = maxX
        self.depth = depth
        self.cornerRadius = cornerRadius
    }
}

/// The compiled glow pipeline, shared by every display.
final class GlowRenderer {
    static let shared = GlowRenderer()
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private init?() {
        let logger = Logger(subsystem: "com.chaitanya.edgebeat", category: "render")
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            logger.error("No Metal device")
            return nil
        }
        do {
            let library = try device.makeLibrary(source: GlowShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: GlowShader.vertexFunction)
            descriptor.fragmentFunction = library.makeFunction(name: GlowShader.fragmentFunction)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            logger.error("Glow shader failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    func makeCommandBuffer() -> MTLCommandBuffer? {
        queue.makeCommandBuffer()
    }

    /// Draws one quad covering `target`. Every pixel is written, so the target
    /// is never loaded or cleared first.
    func encode(_ uniforms: GlowUniforms, into commandBuffer: MTLCommandBuffer,
                target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var values = uniforms
        let length = MemoryLayout<GlowUniforms>.stride
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&values, length: length, index: 0)
        encoder.setFragmentBytes(&values, length: length, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}

/// Hosts the glow for one display as four Metal strips along the edges, so
/// only the band that can light up is ever rendered or composited.
final class GlowView: NSView {
    /// Pixels per point for the strips. The glow is soft, so rendering at one
    /// pixel per point on a Retina display looks the same for a quarter of the
    /// pixels; see `resolutionScale(backing:)`.
    static var renderAtPointResolution = true

    var notch: DisplayNotch? {
        didSet { if notch != oldValue { layoutStrips() } }
    }

    private let animator: GlowAnimator
    private let preferences: AppPreferences
    private let renderState: RenderState
    private let rootLayer = CALayer()
    private let strips: [CAMetalLayer]
    private var displayLink: CADisplayLink?
    private var renderedIdleFrame = false
    private var laidOutThickness: Double?
    private var cancellables: Set<AnyCancellable> = []

    init(frame: NSRect, animator: GlowAnimator, preferences: AppPreferences,
         renderState: RenderState, notch: DisplayNotch?) {
        self.animator = animator
        self.preferences = preferences
        self.renderState = renderState
        self.notch = notch
        strips = (0..<4).map { _ in CAMetalLayer() }
        super.init(frame: frame)

        rootLayer.isGeometryFlipped = true
        layer = rootLayer
        wantsLayer = true
        for strip in strips {
            strip.device = GlowRenderer.shared?.device
            strip.pixelFormat = GlowRenderer.pixelFormat
            strip.framebufferOnly = true
            strip.isOpaque = false
            strip.maximumDrawableCount = 2
            strip.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            strip.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            rootLayer.addSublayer(strip)
        }

        renderState.$isPlaying
            .sink { [weak self] playing in if playing { self?.wake() } }
            .store(in: &cancellables)
        preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.layoutStripsIfThicknessChanged()
                self?.wake()
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil, GlowRenderer.shared != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        applyFrameRate()
        layoutStrips()
        wake()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutStrips()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutStrips()
    }

    /// Resumes drawing after the view went idle.
    func wake() {
        renderedIdleFrame = false
        applyFrameRate()
        displayLink?.isPaused = false
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    static func resolutionScale(backing: CGFloat) -> CGFloat {
        renderAtPointResolution ? 1 : backing
    }

    /// Strip rectangles in points, y down: top (deep enough to wrap the notch),
    /// bottom, then the two sides between them.
    static func stripFrames(size: CGSize, depth: CGFloat, notchDepth: CGFloat) -> [CGRect] {
        let depth = min(depth, size.width / 2, size.height / 2)
        let top = min(size.height / 2, depth + notchDepth)
        let sideHeight = max(0, size.height - top - depth)
        return [
            CGRect(x: 0, y: 0, width: size.width, height: top),
            CGRect(x: 0, y: size.height - depth, width: size.width, height: depth),
            CGRect(x: 0, y: top, width: depth, height: sideHeight),
            CGRect(x: size.width - depth, y: top, width: depth, height: sideHeight),
        ]
    }

    private func layoutStripsIfThicknessChanged() {
        if laidOutThickness != preferences.thickness { layoutStrips() }
    }

    private func layoutStrips() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        laidOutThickness = preferences.thickness
        let depth = GlowAnimator.stripDepth(thickness: preferences.thickness)
        let frames = Self.stripFrames(size: size, depth: depth, notchDepth: notch?.depth ?? 0)
        let scale = Self.resolutionScale(backing: window?.backingScaleFactor ?? 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (strip, rect) in zip(strips, frames) {
            strip.frame = rect
            strip.contentsScale = scale
            strip.drawableSize = CGSize(width: max(1, (rect.width * scale).rounded()),
                                        height: max(1, (rect.height * scale).rounded()))
            strip.isHidden = rect.width < 1 || rect.height < 1
        }
        CATransaction.commit()
        wake()
    }

    private func applyFrameRate() {
        guard let displayLink else { return }
        let reduced = animator.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let rate: Float = reduced ? 30 : 60
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: rate,
                                                               preferred: rate)
    }

    @objc private func step(_ link: CADisplayLink) {
        animator.advance(to: link.timestamp)
        let active = animator.isActive
        if !active && renderedIdleFrame {
            link.isPaused = true
            return
        }
        render()
        renderedIdleFrame = !active
    }

    private func render() {
        guard let renderer = GlowRenderer.shared,
              let commandBuffer = renderer.makeCommandBuffer() else { return }
        let size = bounds.size
        var drawables: [CAMetalDrawable] = []
        for strip in strips where !strip.isHidden {
            guard let drawable = strip.nextDrawable() else { continue }
            let uniforms = animator.uniforms(screenSize: size, strip: strip.frame, notch: notch)
            renderer.encode(uniforms, into: commandBuffer, target: drawable.texture)
            drawables.append(drawable)
        }
        guard !drawables.isEmpty else { return }
        drawables.forEach { commandBuffer.present($0) }
        commandBuffer.addCompletedHandler { buffer in
            RenderStats.shared.recordFrame(gpuTime: buffer.gpuEndTime - buffer.gpuStartTime)
        }
        commandBuffer.commit()
    }
}
