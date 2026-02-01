//
//  ContentViewModel.swift
//  HackBrown
//
//  ViewModel for ContentView. Manages frame sources, pipelines, and alerts.
//  Orchestrates the full driving assistant system.
//

import SwiftUI
import Combine
import CoreVideo

// MARK: - App Mode

/// Operating mode of the app (per PROJECT_SPEC: two mutually exclusive modes + optional demo)
enum AppMode: String, CaseIterable, Identifiable {
    case road = "Road"       // Rear camera - road hazards (OBSTACLE_AHEAD, CLOSING_FAST)
    case driver = "Driver"   // Front camera - driver monitoring (DRIVER_DISTRACTED, DRIVER_DROWSY)
    case demo = "Demo"       // Optional: video file for testing (no camera required)
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .road:
            return "Rear camera — hazard detection"
        case .driver:
            return "Front camera — attention monitoring"
        case .demo:
            return "Video file — testing only"
        }
    }
}

// MARK: - Content View Model

@MainActor
final class ContentViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var sourceMode: SourceMode = .liveRear
    @Published var appMode: AppMode = .road
    @Published var isRunning: Bool = false
    @Published var currentFrameImage: UIImage?
    @Published var fps: Double = 0.0
    
    // Pipeline outputs
    @Published var roadOutput: RoadPipelineOutput?
    @Published var driverOutput: DriverPipelineOutput?
    
    // Alert state
    @Published var currentAlert: AlertType?
    @Published var isAlertActive: Bool = false
    
    // MARK: - Dual Camera State (BeReal-style)
    
    /// Secondary camera frame image (PiP view)
    @Published var secondaryFrameImage: UIImage?
    
    /// Whether front camera is the primary (fullscreen) view
    /// When true: front = fullscreen, back = PiP
    /// When false: back = fullscreen, front = PiP
    @Published var frontIsPrimary: Bool = true
    
    /// Whether device supports dual camera (iPhone XS+)
    @Published var isDualCameraSupported: Bool = false
    
    /// Whether dual camera mode is currently active
    @Published var isDualCameraActive: Bool = false
    
    // MARK: - Pipelines
    
    private var frameSource: FrameSource?
    
    /// Single live camera source — reused for Road/Driver to avoid deallocation crash when switching
    private lazy var liveCameraSource: LiveCameraFrameSource = LiveCameraFrameSource(position: .back)
    
    /// Dual camera source for BeReal-style UI (front + back simultaneously)
    private var dualCameraSource: DualCameraFrameSource?
    
    private let roadPipeline = RoadPipeline()
    private let driverPipeline = DriverPipeline()
    let alertManager = AlertManager()
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    
    // FPS calculation
    private var frameCount: Int = 0
    private var lastFPSUpdate: Date = Date()
    
    // MARK: - Initialization
    
    init() {
        // Check dual camera support on init
        isDualCameraSupported = DualCameraFrameSource.isSupported
        setupBindings()
    }
    
    // MARK: - Setup
    
    private func setupBindings() {
        // Bind road pipeline output
        roadPipeline.$latestOutput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] output in
                self?.roadOutput = output
            }
            .store(in: &cancellables)
        
        // Bind driver pipeline output
        driverPipeline.$latestOutput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] output in
                self?.driverOutput = output
            }
            .store(in: &cancellables)
        
        // Bind alert manager state
        alertManager.$currentAlert
            .receive(on: DispatchQueue.main)
            .sink { [weak self] alert in
                self?.currentAlert = alert
            }
            .store(in: &cancellables)
        
        alertManager.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                self?.isAlertActive = isPlaying
            }
            .store(in: &cancellables)
        
        // Subscribe alert manager to pipelines
        alertManager.subscribeToRoadPipeline(roadPipeline)
        alertManager.subscribeToDriverPipeline(driverPipeline)
    }
    
    // MARK: - Public Methods
    
    func setAppMode(_ mode: AppMode) {
        guard mode != appMode else { return }
        
        let wasRunning = isRunning
        if wasRunning {
            stop()
        }
        
        appMode = mode
        
        // Update source mode to match app mode
        switch mode {
        case .road:
            sourceMode = .liveRear
        case .driver:
            sourceMode = .liveFront
        case .demo:
            sourceMode = .videoFile
        }
        
        if wasRunning {
            start()
        }
    }
    
    func setSourceMode(_ mode: SourceMode) {
        guard mode != sourceMode else { return }
        
        let wasRunning = isRunning
        if wasRunning {
            stop()
        }
        
        sourceMode = mode
        
        if wasRunning {
            start()
        }
    }
    
    func toggleRunning() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }
    
    /// Toggle which camera is primary (fullscreen) vs secondary (PiP)
    /// Called when user taps the PiP view
    /// This switches BOTH the visual display AND which pipeline is running
    func togglePrimaryCamera() {
        guard isDualCameraActive, let dualSource = dualCameraSource else { return }
        
        frontIsPrimary.toggle()
        
        // Swap the images immediately for visual feedback
        let temp = currentFrameImage
        currentFrameImage = secondaryFrameImage
        secondaryFrameImage = temp
        
        // Switch the pipeline to the new primary camera
        // Stop current pipelines
        driverPipeline.stop()
        roadPipeline.stop()
        
        // Start the appropriate pipeline based on which camera is now primary
        if frontIsPrimary {
            // Front camera is primary - run driver monitoring
            let frontAdapter = DualCameraFrontAdapter(dualSource: dualSource)
            frameSource = frontAdapter
            driverPipeline.start(with: frontAdapter)
            print("[ContentViewModel] Switched to front camera - running driver pipeline")
        } else {
            // Back camera is primary - run road monitoring
            let backAdapter = DualCameraBackAdapter(dualSource: dualSource)
            frameSource = backAdapter
            roadPipeline.start(with: backAdapter)
            print("[ContentViewModel] Switched to back camera - running road pipeline")
        }
    }
    
    func start() {
        guard !isRunning else { return }
        
        // Check if we should use dual camera (Driver mode + supported device)
        let useDualCamera = appMode == .driver && isDualCameraSupported
        
        if useDualCamera {
            startDualCamera()
        } else {
            startSingleCamera()
        }
    }
    
    /// Start with single camera (original behavior)
    private func startSingleCamera() {
        // Create frame source
        createFrameSource(for: sourceMode)
        
        guard let source = frameSource else {
            print("[ContentViewModel] No frame source available")
            return
        }
        
        isRunning = true
        isDualCameraActive = false
        resetFPSCounter()
        alertManager.resetCooldowns()
        
        // Subscribe to frames for preview
        subscribeToFrames()
        
        // Start appropriate pipeline(s) — one at a time per spec
        switch appMode {
        case .road, .demo:
            roadPipeline.start(with: source)
        case .driver:
            driverPipeline.start(with: source)
        }
        
        // Start frame source
        source.start()
        
        // Announce system ready
        alertManager.triggerAlert(.systemReady)
    }
    
    /// Start with dual camera (BeReal-style)
    private func startDualCamera() {
        // Cancel existing subscriptions and re-setup bindings
        cancellables.removeAll()
        setupBindings()
        currentFrameImage = nil
        secondaryFrameImage = nil
        
        // Create dual camera source
        dualCameraSource = DualCameraFrameSource()
        
        guard let dualSource = dualCameraSource else {
            print("[ContentViewModel] Failed to create dual camera source, falling back to single camera")
            startSingleCamera()
            return
        }
        
        isRunning = true
        isDualCameraActive = true
        frontIsPrimary = true  // Reset to front camera as primary in Driver mode
        resetFPSCounter()
        alertManager.resetCooldowns()
        
        // Subscribe to both camera feeds
        subscribeToDualCameraFrames()
        
        // Create a wrapper frame source for the pipeline (front camera for driver monitoring)
        // We'll create a simple adapter that forwards front frames to the pipeline
        let frontFrameSource = DualCameraFrontAdapter(dualSource: dualSource)
        frameSource = frontFrameSource
        
        // Start driver pipeline with front camera frames
        driverPipeline.start(with: frontFrameSource)
        
        // Start dual camera capture
        dualSource.start()
        
        // Announce system ready
        alertManager.triggerAlert(.systemReady)
    }
    
    func stop() {
        guard isRunning else { return }
        
        // Stop pipelines first (cancel frame subscriptions)
        roadPipeline.stop()
        driverPipeline.stop()
        alertManager.stopAndClear()
        
        // Stop frame source (live camera is reused, never deallocated — avoids crash)
        frameSource?.stop()
        frameSource = nil
        
        // Stop dual camera if active
        dualCameraSource?.stop()
        dualCameraSource = nil
        
        isRunning = false
        isDualCameraActive = false
        currentFrameImage = nil
        secondaryFrameImage = nil
        roadOutput = nil
        driverOutput = nil
        fps = 0.0
    }
    
    // MARK: - Private Methods
    
    private func createFrameSource(for mode: SourceMode) {
        // Cancel existing subscriptions
        cancellables.removeAll()
        setupBindings()  // Re-setup pipeline bindings
        currentFrameImage = nil
        
        switch mode {
        case .liveRear:
            // Reuse single live camera — reconfigure if switching from front
            liveCameraSource.reconfigure(for: .back)
            frameSource = liveCameraSource
            
        case .liveFront:
            // Reuse single live camera — reconfigure if switching from back
            liveCameraSource.reconfigure(for: .front)
            frameSource = liveCameraSource
            
        case .videoFile:
            // Try bundle resources first (testVid1.mov, then test_video.mp4, then demo.mov)
            if let source = VideoFileFrameSource(bundleResource: "testVid1", withExtension: "mov") {
                frameSource = source
            } else if let source = VideoFileFrameSource(bundleResource: "test_video", withExtension: "mp4") {
                frameSource = source
            } else if let source = VideoFileFrameSource(bundleResource: "demo", withExtension: "mov") {
                frameSource = source
            } else {
                // Fallback: try documents directory
                let docsURL = VideoFileHelper.documentsURL(fileName: "test_video.mp4")
                if VideoFileHelper.fileExists(at: docsURL) {
                    frameSource = VideoFileFrameSource(url: docsURL)
                } else {
                    print("[ContentViewModel] No video file found. Add testVid1.mov (or test_video.mp4 / demo.mov) to the Resources folder and ensure it's in the HackBrown target's Copy Bundle Resources.")
                    frameSource = nil
                }
            }
        }
    }
    
    private func subscribeToFrames() {
        guard let source = frameSource else { return }
        
        source.framePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.processFrame(frame)
            }
            .store(in: &cancellables)
    }
    
    /// Subscribe to both camera feeds from dual camera source
    private func subscribeToDualCameraFrames() {
        guard let dualSource = dualCameraSource else { return }
        
        // Subscribe to front camera frames
        dualSource.frontFramePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.processDualCameraFrame(frame, isFromFrontCamera: true)
            }
            .store(in: &cancellables)
        
        // Subscribe to back camera frames
        dualSource.backFramePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.processDualCameraFrame(frame, isFromFrontCamera: false)
            }
            .store(in: &cancellables)
    }
    
    /// Process frame from dual camera, routing to primary or secondary based on frontIsPrimary
    private func processDualCameraFrame(_ frame: Frame, isFromFrontCamera: Bool) {
        let image = UIImage(pixelBuffer: frame.pixelBuffer)
        
        // Route to primary or secondary based on which camera and frontIsPrimary setting
        if isFromFrontCamera == frontIsPrimary {
            // This camera is currently primary (fullscreen)
            currentFrameImage = image
            updateFPS()
        } else {
            // This camera is currently secondary (PiP)
            secondaryFrameImage = image
        }
    }
    
    private func processFrame(_ frame: Frame) {
        // Convert CVPixelBuffer to UIImage for preview
        currentFrameImage = UIImage(pixelBuffer: frame.pixelBuffer)
        
        // Update FPS
        updateFPS()
    }
    
    private func resetFPSCounter() {
        frameCount = 0
        lastFPSUpdate = Date()
    }
    
    private func updateFPS() {
        frameCount += 1
        
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSUpdate)
        
        // Update FPS every second
        if elapsed >= 1.0 {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            lastFPSUpdate = now
        }
    }
    
    // MARK: - Audio Pre-caching
    
    /// Pre-cache all TTS audio (call on app launch or settings)
    func preCacheAudio() {
        Task {
            await alertManager.preCacheAudio()
        }
    }
}

// MARK: - UIImage Extension

extension UIImage {
    
    /// Create UIImage from CVPixelBuffer
    convenience init?(pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        self.init(cgImage: cgImage)
    }
}

// MARK: - Dual Camera Adapters

/// Adapter that wraps DualCameraFrameSource and exposes only front camera frames
/// This allows the DriverPipeline to receive frames through the standard FrameSource protocol
final class DualCameraFrontAdapter: FrameSource {
    
    var framePublisher: AnyPublisher<Frame, Never> {
        dualSource.frontFramePublisher
    }
    
    var isRunning: Bool {
        dualSource.isRunning
    }
    
    private let dualSource: DualCameraFrameSource
    
    init(dualSource: DualCameraFrameSource) {
        self.dualSource = dualSource
    }
    
    func start() {
        // Dual source is started/stopped by ContentViewModel
        // This adapter just forwards frames
    }
    
    func stop() {
        // Dual source is started/stopped by ContentViewModel
    }
}

/// Adapter that wraps DualCameraFrameSource and exposes only back camera frames
/// This allows the RoadPipeline to receive frames through the standard FrameSource protocol
final class DualCameraBackAdapter: FrameSource {
    
    var framePublisher: AnyPublisher<Frame, Never> {
        dualSource.backFramePublisher
    }
    
    var isRunning: Bool {
        dualSource.isRunning
    }
    
    private let dualSource: DualCameraFrameSource
    
    init(dualSource: DualCameraFrameSource) {
        self.dualSource = dualSource
    }
    
    func start() {
        // Dual source is started/stopped by ContentViewModel
        // This adapter just forwards frames
    }
    
    func stop() {
        // Dual source is started/stopped by ContentViewModel
    }
}
