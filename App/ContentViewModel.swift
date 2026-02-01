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
import CoreImage
import SmartSpectraSwiftSDK

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
    
    // MARK: - Heart Rate State (SmartSpectra)
    
    /// Current heart rate in BPM (from SmartSpectra SDK) - average of last 5 measurements
    @Published var heartRateBPM: Double?
    
    /// Whether SmartSpectra is actively providing data
    @Published var isSmartSpectraActive: Bool = false
    
    /// Timer for heart rate polling
    private var heartRateTimer: Timer?
    
    /// Timer for SmartSpectra frame polling
    private var smartSpectraFrameTimer: Timer?
    
    /// Queue to store last 5 heart rate measurements for averaging
    private var heartRateHistory: [Double] = []
    private let maxHeartRateHistorySize: Int = 5
    
    // MARK: - Vision Face Analysis (runs on SmartSpectra frames)
    
    /// Vision attention analyzer for blink and gaze detection
    private let visionAttention = VisionAttention()
    
    /// Timer for Vision face analysis on SmartSpectra frames
    private var visionAnalysisTimer: Timer?
    
    /// Latest attention state from Vision analysis
    @Published var attentionState: AttentionState?
    
    /// Flag to prevent overlapping Vision analysis
    private var isVisionAnalysisBusy = false
    
    /// Reusable CIContext for efficient pixel buffer conversion
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
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
    
    // MARK: - Video Picker State
    
    /// Whether the video picker sheet is showing
    @Published var showingVideoPicker: Bool = false
    
    /// Currently selected video filename (with extension)
    @Published var selectedVideoFileName: String?
    
    /// List of demo videos (populated when demo starts, for cycling)
    @Published var demoVideos: [DemoVideo] = []
    
    /// Index into demoVideos for the currently playing demo video
    @Published var currentDemoVideoIndex: Int = 0
    
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
        
        // Warm up the road pipeline to ensure YOLO model is fully loaded.
        // This prevents the first-frame delay and ensures demo mode works immediately.
        roadPipeline.warmUp()
        
        setupBindings()
        
        print("[ContentViewModel] Initialized, road pipeline ready")
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
    /// Also clears data from the inactive pipeline
    func togglePrimaryCamera() {
        guard isDualCameraActive, let dualSource = dualCameraSource else { return }
        
        frontIsPrimary.toggle()
        
        // Swap the images immediately for visual feedback
        let temp = currentFrameImage
        currentFrameImage = secondaryFrameImage
        secondaryFrameImage = temp
        
        // CRITICAL: Clear ALL subscriptions before switching modes
        // This prevents subscription accumulation and reduces CPU load
        cancellables.removeAll()
        setupBindings()  // Re-add pipeline bindings
        
        // Switch the pipeline to the new primary camera
        // Stop current pipelines
        driverPipeline.stop()
        roadPipeline.stop()
        
        // Start the appropriate pipeline based on which camera is now primary
        // Also clear the data from the pipeline we're switching away from
        if frontIsPrimary {
            // Front camera is primary - run driver monitoring
            // Clear road detection data from display
            roadOutput = nil
            
            // Stop dual camera - SmartSpectra will take over front camera
            dualSource.stop()
            
            // Start heart rate monitoring with SmartSpectra (takes over front camera)
            startHeartRateMonitoring()
            
            // Subscribe to SmartSpectra image updates for main view
            subscribeToSmartSpectraFrames()
            
            // Use LiveCameraFrameSource for back camera PiP only
            liveCameraSource.reconfigure(for: .back)
            subscribeToBackCameraForPiP()
            liveCameraSource.start()
            
            // Note: Driver pipeline is NOT started - SmartSpectra controls the camera
            // Heart rate comes from SmartSpectra SDK directly via pollHeartRate()
            // Vision face analysis would conflict with SmartSpectra's camera access
            frameSource = nil
            
            print("[ContentViewModel] Switched to front camera - SmartSpectra active for heart rate")
        } else {
            // Back camera is primary - run road monitoring
            // Clear driver detection data from display
            driverOutput = nil
            
            // Stop heart rate monitoring
            stopHeartRateMonitoring()
            
            // Stop live camera if it was running for PiP
            liveCameraSource.stop()
            
            // Restart dual camera
            dualCameraSource = DualCameraFrameSource()
            guard let newDualSource = dualCameraSource else {
                print("[ContentViewModel] Failed to recreate dual camera")
                return
            }
            
            // Re-subscribe to dual camera frames
            subscribeToDualCameraFrames()
            
            let backAdapter = DualCameraBackAdapter(dualSource: newDualSource)
            frameSource = backAdapter
            roadPipeline.start(with: backAdapter)
            newDualSource.start()
            
            print("[ContentViewModel] Switched to back camera - road pipeline active")
        }
    }
    
    func start() {
        guard !isRunning else { return }
        
        // Always use dual camera if supported (default behavior for Start button)
        if isDualCameraSupported {
            startDualCamera()
        } else {
            // Fallback to single back camera with road pipeline
            appMode = .road
            sourceMode = .liveRear
            startSingleCamera()
        }
    }
    
    /// Start demo mode with video file playback
    func startDemo() {
        guard !isRunning else { return }
        
        // Scan for available videos
        let availableVideos = VideoManager.scanBundleForVideos()
        
        if availableVideos.isEmpty {
            print("[ContentViewModel] No demo videos found in bundle")
            return
        }
        
        // If only one video, start it directly
        if availableVideos.count == 1 {
            let video = availableVideos[0]
            startDemoWithVideo(video.name, ext: video.fileExtension)
        } else {
            // Show picker for multiple videos
            showingVideoPicker = true
        }
    }
    
    /// Start demo mode with a specific video
    /// - Parameters:
    ///   - name: Video name (without extension)
    ///   - ext: File extension (.mov, .mp4, .m4v)
    func startDemoWithVideo(_ name: String, ext: String) {
        guard !isRunning else { return }
        
        // Cancel existing subscriptions and re-setup bindings (same as startDualCamera/startSingleCamera)
        // This ensures bindings are fresh and properly connected
        cancellables.removeAll()
        setupBindings()
        
        // Clear any stale state
        currentFrameImage = nil
        roadOutput = nil
        driverOutput = nil
        
        appMode = .demo
        sourceMode = .videoFile
        selectedVideoFileName = "\(name).\(ext)"
        
        // Demo shows road-style video: use back-camera overlay (bounding boxes + road status)
        frontIsPrimary = false
        
        // Create video source
        guard let videoSource = VideoManager.loadVideo(named: name, ext: ext) else {
            print("[ContentViewModel] Failed to load video: \(name).\(ext)")
            return
        }
        
        frameSource = videoSource
        
        isRunning = true
        isDualCameraActive = false
        resetFPSCounter()
        alertManager.resetCooldowns()
        
        // Start road pipeline FIRST so it subscribes before any frames are emitted
        roadPipeline.start(with: videoSource)
        
        // Subscribe to frames for UI preview
        subscribeToFrames()
        
        // Start video playback AFTER pipeline and UI are subscribed
        videoSource.start()
        
        // Announce system ready
        alertManager.triggerAlert(.systemReady)
        
        // Store demo list and index for cycling
        let allVideos = VideoManager.scanBundleForVideos()
        demoVideos = allVideos
        currentDemoVideoIndex = allVideos.firstIndex { $0.name == name && $0.fileExtension == ext } ?? 0
        
        print("[ContentViewModel] Started demo with video: \(name).\(ext), YOLO pipeline active")
    }
    
    /// Cycle to the next demo video (wraps to first after last)
    func cycleToNextDemoVideo() {
        guard isRunning, appMode == .demo, !demoVideos.isEmpty else { return }
        switchToDemoVideo(at: (currentDemoVideoIndex + 1) % demoVideos.count)
    }
    
    /// Cycle to the previous demo video (wraps to last after first)
    func cycleToPreviousDemoVideo() {
        guard isRunning, appMode == .demo, !demoVideos.isEmpty else { return }
        let prev = (currentDemoVideoIndex - 1 + demoVideos.count) % demoVideos.count
        switchToDemoVideo(at: prev)
    }
    
    /// Switch demo to the video at the given index (used by Prev/Next)
    private func switchToDemoVideo(at index: Int) {
        guard index >= 0, index < demoVideos.count else { return }
        
        frameSource?.stop()
        frameSource = nil
        cancellables.removeAll()
        setupBindings()
        
        currentDemoVideoIndex = index
        let video = demoVideos[index]
        selectedVideoFileName = video.fileName
        
        guard let videoSource = VideoManager.loadVideo(named: video.name, ext: video.fileExtension) else {
            print("[ContentViewModel] Failed to load video: \(video.fileName)")
            return
        }
        
        frameSource = videoSource
        currentFrameImage = nil
        roadOutput = nil
        resetFPSCounter()
        
        roadPipeline.start(with: videoSource)
        subscribeToFrames()
        videoSource.start()
        
        print("[ContentViewModel] Demo video: \(video.fileName)")
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
        
        // Enable heart rate reading if in driver mode (no camera start - just read from SDK buffer)
        if appMode == .driver {
            driverPipeline.setSmartSpectraReady(true)
        }
        
        // Announce system ready
        alertManager.triggerAlert(.systemReady)
    }
    
    /// Start with dual camera (BeReal-style)
    /// Default: back camera fullscreen (road pipeline), front camera in PiP
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
            appMode = .road
            sourceMode = .liveRear
            startSingleCamera()
            return
        }
        
        isRunning = true
        isDualCameraActive = true
        frontIsPrimary = false  // Back camera as primary (fullscreen) by default
        resetFPSCounter()
        alertManager.resetCooldowns()
        
        // Clear any previous pipeline data
        roadOutput = nil
        driverOutput = nil
        
        // Subscribe to both camera feeds
        subscribeToDualCameraFrames()
        
        // Create a wrapper frame source for the pipeline (back camera for road monitoring)
        let backFrameSource = DualCameraBackAdapter(dualSource: dualSource)
        frameSource = backFrameSource
        
        // Start road pipeline with back camera frames (default)
        roadPipeline.start(with: backFrameSource)
        
        // Start dual camera capture
        dualSource.start()
        
        // Start SmartSpectra processing AFTER camera is running (only if front camera will be used)
        // We'll start it when user switches to front camera, not immediately
        // This prevents conflicts with camera initialization
        
        // Announce system ready
        alertManager.triggerAlert(.systemReady)
        
        print("[ContentViewModel] Started dual camera - back camera primary, road pipeline active")
    }
    
    func stop() {
        guard isRunning else { return }
        
        // Stop heart rate monitoring
        stopHeartRateMonitoring()
        
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
        heartRateBPM = nil
        fps = 0.0
        demoVideos = []
        currentDemoVideoIndex = 0
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
            // Use selectedVideoFileName if available (from video picker)
            if let fileName = selectedVideoFileName {
                let components = fileName.split(separator: ".")
                if components.count == 2,
                   let source = VideoManager.loadVideo(named: String(components[0]), ext: String(components[1])) {
                    frameSource = source
                    return
                }
            }
            
            // Fallback to first available video
            let videos = VideoManager.scanBundleForVideos()
            if let first = videos.first,
               let source = VideoManager.loadVideo(named: first.name, ext: first.fileExtension) {
                frameSource = source
            } else {
                print("[ContentViewModel] No video files found. Add .mov, .mp4, or .m4v files to Resources folder.")
                frameSource = nil
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
    
    /// Subscribe to SmartSpectra frame updates (for driver mode)
    private func subscribeToSmartSpectraFrames() {
        // Stop any existing timer first
        smartSpectraFrameTimer?.invalidate()
        
        // Poll at 12fps - smooth enough for display, efficient
        smartSpectraFrameTimer = Timer.scheduledTimer(withTimeInterval: 1.0/12.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isSmartSpectraActive else {
                timer.invalidate()
                return
            }
            
            if let image = SmartSpectraVitalsProcessor.shared.imageOutput {
                self.currentFrameImage = image
            }
        }
    }
    
    /// Stop SmartSpectra frame polling
    private func stopSmartSpectraFramePolling() {
        smartSpectraFrameTimer?.invalidate()
        smartSpectraFrameTimer = nil
    }
    
    /// Subscribe to back camera only for PiP (when SmartSpectra is handling front)
    private func subscribeToBackCameraForPiP() {
        liveCameraSource.framePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                guard let self = self else { return }
                // Only update secondary (PiP) image
                self.secondaryFrameImage = UIImage(pixelBuffer: frame.pixelBuffer)
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
    
    // MARK: - Heart Rate Monitoring (SmartSpectra)
    
    /// Start heart rate monitoring with SmartSpectra
    /// Call this when switching to driver mode (front camera)
    func startHeartRateMonitoring() {
        // Stop any existing timer
        stopHeartRateMonitoring()
        
        // Start SmartSpectra processing
        let vitalsProcessor = SmartSpectraVitalsProcessor.shared
        vitalsProcessor.startProcessing()
        vitalsProcessor.startRecording()
        
        isSmartSpectraActive = true
        driverPipeline.setSmartSpectraReady(true)
        
        // Start polling timer (every 500ms = 2Hz)
        heartRateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollHeartRate()
        }
        
        // Start Vision face analysis on SmartSpectra frames
        startVisionAnalysis()
    }
    
    /// Stop heart rate monitoring
    func stopHeartRateMonitoring() {
        heartRateTimer?.invalidate()
        heartRateTimer = nil
        
        // Stop frame polling timer
        stopSmartSpectraFramePolling()
        
        // Stop Vision analysis
        stopVisionAnalysis()
        
        if isSmartSpectraActive {
            let vitalsProcessor = SmartSpectraVitalsProcessor.shared
            vitalsProcessor.stopRecording()
            vitalsProcessor.stopProcessing()
            isSmartSpectraActive = false
        }
        
        driverPipeline.setSmartSpectraReady(false)
        heartRateBPM = nil
        heartRateHistory.removeAll()
    }
    
    /// Poll heart rate from SmartSpectra SDK (called every 500ms)
    private func pollHeartRate() {
        guard let metrics = SmartSpectraSwiftSDK.shared.metricsBuffer,
              !metrics.pulse.rate.isEmpty,
              let hr = metrics.pulse.rate.last else { return }
        
        let bpm = Double(hr.value)
        guard bpm > 0 && bpm < 250 else { return }
        
        // Rolling average of last 5 measurements
        heartRateHistory.append(bpm)
        if heartRateHistory.count > maxHeartRateHistorySize {
            heartRateHistory.removeFirst()
        }
        heartRateBPM = heartRateHistory.reduce(0, +) / Double(heartRateHistory.count)
    }
    
    /// Get SmartSpectra camera image (for driver mode display)
    func getSmartSpectraImage() -> UIImage? {
        return SmartSpectraVitalsProcessor.shared.imageOutput
    }
    
    // MARK: - Vision Face Analysis (Blink & Gaze Detection)
    
    /// Start Vision face analysis on SmartSpectra frames
    private func startVisionAnalysis() {
        stopVisionAnalysis()
        visionAttention.reset()
        isVisionAnalysisBusy = false
        
        // Run at 8Hz (every 125ms) - good balance of responsiveness and efficiency
        visionAnalysisTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
            self?.analyzeFrameWithVision()
        }
    }
    
    /// Stop Vision face analysis
    private func stopVisionAnalysis() {
        visionAnalysisTimer?.invalidate()
        visionAnalysisTimer = nil
        attentionState = nil
        isVisionAnalysisBusy = false
    }
    
    /// Analyze current SmartSpectra frame with Vision for blink/gaze detection
    private func analyzeFrameWithVision() {
        // Skip if still processing previous frame (prevents buildup)
        guard !isVisionAnalysisBusy else { return }
        
        guard isSmartSpectraActive,
              let image = SmartSpectraVitalsProcessor.shared.imageOutput else {
            return
        }
        
        isVisionAnalysisBusy = true
        
        // Convert and analyze on background thread
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            // Convert UIImage to CVPixelBuffer (optimized)
            guard let pixelBuffer = self.convertToPixelBufferFast(image) else {
                DispatchQueue.main.async { self.isVisionAnalysisBusy = false }
                return
            }
            
            // Analyze for blinks and gaze
            let state = self.visionAttention.analyzeAttention(in: pixelBuffer)
            let events = self.visionAttention.checkForEvents(state: state)
            
            // Update UI on main thread
            DispatchQueue.main.async {
                self.attentionState = state
                self.isVisionAnalysisBusy = false
                
                // Handle events (trigger alerts) - only for actual issues
                for event in events {
                    self.handleVisionEvent(event)
                }
            }
        }
    }
    
    /// Convert UIImage to CVPixelBuffer for Vision analysis (full resolution for accuracy)
    private func convertToPixelBufferFast(_ image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        
        // Use full resolution for better face detection accuracy
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
    
    /// Handle Vision attention events and trigger alerts
    private func handleVisionEvent(_ event: AttentionEvent) {
        switch event.type {
        case .repeatedDrowsyBlinks:
            alertManager.triggerAlert(.drowsyBlinks)
        case .drowsiness:
            alertManager.triggerAlert(.drowsy)
        case .eyesOffRoad:
            alertManager.triggerAlert(.keepEyesOnRoad)
        case .noFaceDetected:
            break  // Silent - don't alert for missing face
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
    
    /// Convert UIImage to CVPixelBuffer for Vision analysis
    func toPixelBuffer() -> CVPixelBuffer? {
        guard let cgImage = self.cgImage else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return buffer
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
