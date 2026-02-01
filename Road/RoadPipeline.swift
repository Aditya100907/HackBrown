//
//  RoadPipeline.swift
//  HackBrown
//
//  Orchestrates road hazard detection: frames → YOLO detector → heuristics → events
//  Processes frames from rear camera to detect vehicles, pedestrians, and dangerous situations.
//

import Foundation
import Combine
import CoreVideo

// MARK: - Road Pipeline Output

/// Output from the road pipeline for each processed frame
struct RoadPipelineOutput {
    /// All detected objects in the frame
    let detections: [DetectedObject]
    
    /// Estimated motion vectors for detections (normalized units per second)
    let motionVectors: [UUID: CGPoint]
    
    /// Any hazard events triggered
    let hazardEvents: [RoadHazardEvent]
    
    /// Processing timestamp
    let timestamp: Date
    
    /// Whether any critical hazards were detected
    var hasCriticalHazard: Bool {
        hazardEvents.contains { $0.severity >= .high }
    }
}

// MARK: - Road Pipeline

/// Main road monitoring pipeline
/// Subscribes to a FrameSource and emits detection results and hazard events
final class RoadPipeline: ObservableObject {
    
    // MARK: - Published State
    
    /// Latest detection output (for UI binding)
    @Published private(set) var latestOutput: RoadPipelineOutput?
    
    /// Whether the pipeline is currently processing
    @Published private(set) var isProcessing: Bool = false
    
    // MARK: - Publishers
    
    /// Publisher for hazard events (subscribe to receive alerts)
    var hazardEventPublisher: AnyPublisher<RoadHazardEvent, Never> {
        hazardEventSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for all pipeline outputs
    var outputPublisher: AnyPublisher<RoadPipelineOutput, Never> {
        outputSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Private Properties
    
    private let detector: ObjectDetector
    private let heuristics: RoadHeuristics
    
    private let hazardEventSubject = PassthroughSubject<RoadHazardEvent, Never>()
    private let outputSubject = PassthroughSubject<RoadPipelineOutput, Never>()
    
    private var frameSubscription: AnyCancellable?
    private let processingQueue = DispatchQueue(label: "com.hackbrown.road.processing", qos: .userInitiated)
    
    /// Flag to skip frames if still processing previous one (drop stale frames)
    private var isCurrentlyProcessing = false
    private let processingLock = NSLock()
    
    // MARK: - Initialization
    
    init(detector: ObjectDetector? = nil) {
        self.detector = detector ?? ObjectDetector()
        self.heuristics = RoadHeuristics()
        
        // Log model readiness
        print("[RoadPipeline] Initialized, detector ready: \(self.detector.isReady)")
    }
    
    /// Warm up the detector by ensuring the model is loaded and ready
    /// Call this on app launch to avoid first-frame delay
    func warmUp() {
        print("[RoadPipeline] Warming up detector, ready: \(detector.isReady)")
    }
    
    // MARK: - Pipeline Control
    
    /// Start processing frames from the given source
    /// - Parameter source: Frame source (live camera or video file)
    func start(with source: FrameSource) {
        stop()  // Stop any existing subscription
        
        isProcessing = true
        heuristics.reset()
        
        frameSubscription = source.framePublisher
            .sink { [weak self] frame in
                self?.processFrame(frame)
            }
    }
    
    /// Stop processing
    func stop() {
        frameSubscription?.cancel()
        frameSubscription = nil
        isProcessing = false
        latestOutput = nil
    }
    
    // MARK: - Frame Processing
    
    private func processFrame(_ frame: Frame) {
        // Drop frame if still processing previous one (prioritize latency)
        processingLock.lock()
        guard !isCurrentlyProcessing else {
            processingLock.unlock()
            return
        }
        isCurrentlyProcessing = true
        processingLock.unlock()
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let timestamp = Date()
            
            // Run object detection
            let detections = self.detector.detect(in: frame.pixelBuffer)
            
            // Run heuristics analysis
            let analysis = self.heuristics.analyze(detections: detections, timestamp: timestamp)
            
            // Create output
            let output = RoadPipelineOutput(
                detections: detections,
                motionVectors: analysis.motionVectors,
                hazardEvents: analysis.events,
                timestamp: timestamp
            )
            
            // Publish results
            DispatchQueue.main.async {
                self.latestOutput = output
                self.outputSubject.send(output)
                
                // Emit individual hazard events
                for event in analysis.events {
                    self.hazardEventSubject.send(event)
                }
            }
            
            // Mark as ready for next frame
            self.processingLock.lock()
            self.isCurrentlyProcessing = false
            self.processingLock.unlock()
        }
    }
}

// MARK: - Convenience Extensions

extension RoadPipelineOutput {
    /// Get detections filtered to vehicles only
    var vehicles: [DetectedObject] {
        detections.filter { $0.label.isVehicle }
    }
    
    /// Get detections filtered to vulnerable road users (pedestrians, cyclists)
    var vulnerableRoadUsers: [DetectedObject] {
        detections.filter { $0.label.isVulnerableRoadUser }
    }
}
