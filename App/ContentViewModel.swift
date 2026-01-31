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

/// Operating mode of the app
enum AppMode: String, CaseIterable, Identifiable {
    case roadMonitoring = "Road"       // Rear camera - road hazards
    case driverMonitoring = "Driver"   // Front camera - attention
    case dualMode = "Dual"             // Both (requires dual camera setup)
    case demo = "Demo"                 // Video file playback
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .roadMonitoring:
            return "Rear camera monitoring road hazards"
        case .driverMonitoring:
            return "Front camera monitoring driver attention"
        case .dualMode:
            return "Both cameras active (dual pipeline)"
        case .demo:
            return "Demo mode with video file"
        }
    }
}

// MARK: - Content View Model

@MainActor
final class ContentViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var sourceMode: SourceMode = .liveRear
    @Published var appMode: AppMode = .roadMonitoring
    @Published var isRunning: Bool = false
    @Published var currentFrameImage: UIImage?
    @Published var fps: Double = 0.0
    
    // Pipeline outputs
    @Published var roadOutput: RoadPipelineOutput?
    @Published var driverOutput: DriverPipelineOutput?
    
    // Alert state
    @Published var currentAlert: AlertType?
    @Published var isAlertActive: Bool = false
    
    // MARK: - Pipelines
    
    private var frameSource: FrameSource?
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
        case .roadMonitoring:
            sourceMode = .liveRear
        case .driverMonitoring:
            sourceMode = .liveFront
        case .dualMode:
            sourceMode = .liveRear  // Primary is rear for road
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
    
    func start() {
        guard !isRunning else { return }
        
        // Create frame source
        createFrameSource(for: sourceMode)
        
        guard let source = frameSource else {
            print("[ContentViewModel] No frame source available")
            return
        }
        
        isRunning = true
        resetFPSCounter()
        alertManager.resetCooldowns()
        
        // Subscribe to frames for preview
        subscribeToFrames()
        
        // Start appropriate pipeline(s)
        switch appMode {
        case .roadMonitoring, .demo:
            roadPipeline.start(with: source)
            
        case .driverMonitoring:
            driverPipeline.start(with: source)
            
        case .dualMode:
            // In dual mode, road uses rear, driver uses front
            // For simplicity, we just run road pipeline with current source
            // A full implementation would use two separate sources
            roadPipeline.start(with: source)
            // TODO: Create second source for driver pipeline
        }
        
        // Start frame source
        source.start()
        
        // Announce system ready
        alertManager.triggerAlert(.systemReady)
    }
    
    func stop() {
        guard isRunning else { return }
        
        frameSource?.stop()
        roadPipeline.stop()
        driverPipeline.stop()
        alertManager.stopAndClear()
        
        isRunning = false
        currentFrameImage = nil
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
        
        // Create appropriate source
        switch mode {
        case .liveRear:
            frameSource = LiveCameraFrameSource(position: .back)
            
        case .liveFront:
            frameSource = LiveCameraFrameSource(position: .front)
            
        case .videoFile:
            // Try to load from bundle, or use a placeholder
            if let source = VideoFileFrameSource(bundleResource: "test_video", withExtension: "mp4") {
                frameSource = source
            } else if let source = VideoFileFrameSource(bundleResource: "demo", withExtension: "mov") {
                frameSource = source
            } else {
                // Fallback: try documents directory
                let docsURL = VideoFileHelper.documentsURL(fileName: "test_video.mp4")
                if VideoFileHelper.fileExists(at: docsURL) {
                    frameSource = VideoFileFrameSource(url: docsURL)
                } else {
                    print("[ContentViewModel] No video file found. Add test_video.mp4 to bundle or Documents.")
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
