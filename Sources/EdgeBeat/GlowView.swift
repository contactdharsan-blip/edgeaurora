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
    /// Pixels per point for the strips. The aurora's start and end lines are
    /// crisp, so the strips render at the display's full backing scale; a soft
    /// glow could get away with one pixel per point, a sharp line cannot.
    static var renderAtPointResolution = false

    var notch: DisplayNotch? {
        didSet { if notch != oldValue { layoutStrips() } }
    }

    /// The frosted band behind this view; it follows the glow's fade.
    weak var backdrop: FrostedBorderView? {
        didSet { layoutStrips() }
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
            // The shader writes P3-encoded colour so the panel's wider gamut is used.
            strip.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
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
        backdrop?.configure(depth: GlowAnimator.frostDepth(thickness: preferences.thickness),
                            cornerRadius: GlowAnimator.cornerRadius(for: size))
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
        backdrop?.update(visibility: preferences.frostedGlass ? animator.visibility : 0)
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

/// Frosted glass behind the aurora: the system's own behind-window blur, masked
/// so it is strongest at the screen edge and fades out toward the middle. It
/// fades with the glow and is hidden outright when nothing plays, so it costs
/// nothing while idle.
final class FrostedBorderView: NSVisualEffectView {
    private var maskKey: SIMD2<Double>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(depth: CGFloat, cornerRadius: CGFloat) {
        let key = SIMD2(Double(depth), Double(cornerRadius))
        guard maskKey != key else { return }
        maskKey = key
        maskImage = Self.borderMask(depth: depth, cornerRadius: cornerRadius)
    }

    /// Alpha follows the glow in 5% steps, so a steady glow never touches the
    /// window server.
    func update(visibility: Float) {
        let target = CGFloat((visibility * 20).rounded() / 20)
        guard target > 0 else {
            if !isHidden { isHidden = true }
            return
        }
        if isHidden { isHidden = false }
        if alphaValue != target { alphaValue = target }
    }

    /// A nine-part mask: opaque at the rounded screen edge, easing to clear at
    /// `depth`, with a stretchable clear centre.
    static func borderMask(depth: CGFloat, cornerRadius: CGFloat) -> NSImage {
        let scale: CGFloat = 2
        let side = depth * 2 + 2
        let pixels = Int((side * scale).rounded())
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        let half = side / 2
        for y in 0..<pixels {
            for x in 0..<pixels {
                let px = (CGFloat(x) + 0.5) / scale - half
                let py = (CGFloat(y) + 0.5) / scale - half
                let qx = abs(px) - half + cornerRadius
                let qy = abs(py) - half + cornerRadius
                let outside = hypot(max(qx, 0), max(qy, 0))
                let inside = min(max(qx, qy), 0)
                let distance = -(outside + inside - cornerRadius)
                let t = min(1, max(0, (distance - depth * 0.15) / (depth * 0.85)))
                let alpha = UInt8((1 - t * t * (3 - 2 * t)) * 255)
                let index = (y * pixels + x) * 4
                bytes[index] = alpha
                bytes[index + 1] = alpha
                bytes[index + 2] = alpha
                bytes[index + 3] = alpha
            }
        }
        let image: NSImage
        if let provider = CGDataProvider(data: Data(bytes) as CFData),
           let cgImage = CGImage(width: pixels, height: pixels, bitsPerComponent: 8,
                                 bitsPerPixel: 32, bytesPerRow: pixels * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) {
            image = NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
        } else {
            image = NSImage(size: NSSize(width: side, height: side))
        }
        image.capInsets = NSEdgeInsets(top: depth, left: depth, bottom: depth, right: depth)
        image.resizingMode = .stretch
        return image
    }
}
