//
//  DriverPipeline.swift
//  HackBrown
//
//  Orchestrates driver monitoring: frames → Vision + Presage → attention events
//  Processes frames from front camera to detect distraction and drowsiness.
//

import Foundation
import Combine
import CoreVideo

// MARK: - Driver Pipeline Output

/// Output from the driver pipeline for each processed frame
struct DriverPipelineOutput {
    /// Vision-based attention state
    let attentionState: AttentionState
    
    /// Presage output (attention/fatigue scores)
    let presageOutput: PresageOutput
    
    /// Combined attention events from both sources
    let events: [AttentionEvent]
    
    /// Processing timestamp
    let timestamp: Date
    
    /// Whether driver attention is currently OK
    var isAttentive: Bool {
        attentionState.eyesOpen &&
        attentionState.gazeDirection.isOnRoad &&
        !presageOutput.fatigueScore.isNaN &&
        presageOutput.fatigueScore < 0.6
    }
}

// MARK: - Unified Driver Event

/// Unified event type for the alert system
struct DriverEvent {
    let type: DriverEventType
    let severity: AttentionSeverity
    let timestamp: Date
    let description: String
    let duration: TimeInterval?
}

enum DriverEventType: String {
    case distraction = "distraction"
    case drowsiness = "drowsiness"
    case lowAttention = "low_attention"
    case highFatigue = "high_fatigue"
}

// MARK: - Driver Pipeline

/// Main driver monitoring pipeline
/// Subscribes to a FrameSource and emits attention/fatigue events
final class DriverPipeline: ObservableObject {
    
    // MARK: - Published State
    
    /// Latest pipeline output (for UI binding)
    @Published private(set) var latestOutput: DriverPipelineOutput?
    
    /// Whether the pipeline is currently processing
    @Published private(set) var isProcessing: Bool = false
    
    // MARK: - Publishers
    
    /// Publisher for driver events (subscribe to receive alerts)
    var eventPublisher: AnyPublisher<DriverEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for all pipeline outputs
    var outputPublisher: AnyPublisher<DriverPipelineOutput, Never> {
        outputSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Private Properties
    
    private let visionAttention: VisionAttention
    private let presageIntegration: PresageIntegration
    
    private let eventSubject = PassthroughSubject<DriverEvent, Never>()
    private let outputSubject = PassthroughSubject<DriverPipelineOutput, Never>()
    
    private var frameSubscription: AnyCancellable?
    private let processingQueue = DispatchQueue(label: "com.hackbrown.driver.processing", qos: .userInitiated)
    
    /// Flag to skip frames if still processing previous one (drop stale frames)
    private var isCurrentlyProcessing = false
    private let processingLock = NSLock()
    
    /// Tracking for event escalation
    private var lastEventTime: [DriverEventType: Date] = [:]
    private let eventCooldown: TimeInterval = 3.0  // Don't repeat same event within 3s
    
    // MARK: - Initialization
    
    init(presageProvider: PresageProvider? = nil) {
        self.visionAttention = VisionAttention()
        self.presageIntegration = PresageIntegration(provider: presageProvider)
    }
    
    // MARK: - Pipeline Control
    
    /// Start processing frames from the given source
    /// - Parameter source: Frame source (live camera or video file)
    func start(with source: FrameSource) {
        stop()  // Stop any existing subscription
        
        isProcessing = true
        visionAttention.reset()
        presageIntegration.start()
        lastEventTime.removeAll()
        
        frameSubscription = source.framePublisher
            .sink { [weak self] frame in
                self?.processFrame(frame)
            }
    }
    
    /// Stop processing
    func stop() {
        frameSubscription?.cancel()
        frameSubscription = nil
        presageIntegration.stop()
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
            
            // Run Vision face landmark analysis
            let attentionState = self.visionAttention.analyzeAttention(in: frame.pixelBuffer)
            
            // Run Presage analysis
            let presageOutput = self.presageIntegration.processFrame(frame.pixelBuffer)
            
            // Check for Vision-based events
            let visionEvents = self.visionAttention.checkForEvents(state: attentionState)
            
            // Convert to unified events and check Presage signals
            var unifiedEvents = self.convertVisionEvents(visionEvents)
            unifiedEvents.append(contentsOf: self.checkPresageEvents(presageOutput, timestamp: timestamp))
            
            // Create output
            let output = DriverPipelineOutput(
                attentionState: attentionState,
                presageOutput: presageOutput,
                events: visionEvents,
                timestamp: timestamp
            )
            
            // Publish results
            DispatchQueue.main.async {
                self.latestOutput = output
                self.outputSubject.send(output)
                
                // Emit individual events (with cooldown)
                for event in unifiedEvents {
                    self.emitEventIfNotCoolingDown(event)
                }
            }
            
            // Mark as ready for next frame
            self.processingLock.lock()
            self.isCurrentlyProcessing = false
            self.processingLock.unlock()
        }
    }
    
    // MARK: - Event Processing
    
    /// Convert Vision attention events to unified driver events
    private func convertVisionEvents(_ visionEvents: [AttentionEvent]) -> [DriverEvent] {
        visionEvents.map { event in
            let eventType: DriverEventType
            switch event.type {
            case .eyesOffRoad:
                eventType = .distraction
            case .drowsiness:
                eventType = .drowsiness
            case .noFaceDetected:
                eventType = .distraction
            }
            
            return DriverEvent(
                type: eventType,
                severity: event.severity,
                timestamp: event.timestamp,
                description: event.description,
                duration: event.duration
            )
        }
    }
    
    /// Check Presage output for additional events
    private func checkPresageEvents(_ output: PresageOutput, timestamp: Date) -> [DriverEvent] {
        var events: [DriverEvent] = []
        
        // Check for low attention from Presage
        if presageIntegration.hasLowAttention(output) {
            events.append(DriverEvent(
                type: .lowAttention,
                severity: output.attentionScore < 0.3 ? .high : .medium,
                timestamp: timestamp,
                description: "Low attention detected (Presage: \(String(format: "%.0f%%", output.attentionScore * 100)))",
                duration: nil
            ))
        }
        
        // Check for high fatigue from Presage
        if presageIntegration.hasHighFatigue(output) {
            events.append(DriverEvent(
                type: .highFatigue,
                severity: output.fatigueScore > 0.8 ? .critical : .high,
                timestamp: timestamp,
                description: "High fatigue detected (Presage: \(String(format: "%.0f%%", output.fatigueScore * 100)))",
                duration: nil
            ))
        }
        
        return events
    }
    
    /// Emit event only if not within cooldown period
    private func emitEventIfNotCoolingDown(_ event: DriverEvent) {
        let now = Date()
        
        if let lastTime = lastEventTime[event.type] {
            guard now.timeIntervalSince(lastTime) >= eventCooldown else {
                return  // Still cooling down
            }
        }
        
        lastEventTime[event.type] = now
        eventSubject.send(event)
    }
}
