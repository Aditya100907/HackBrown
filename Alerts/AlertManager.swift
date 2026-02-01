//
//  AlertManager.swift
//  HackBrown
//
//  Central alert manager: receives events from road/driver pipelines,
//  applies cooldowns and priority ordering, dispatches to TTS.
//

import Foundation
import Combine

// MARK: - Alert Manager

/// Manages alert queue, cooldowns, and TTS dispatch
/// Priority: road hazards > distraction > drowsiness
@MainActor
final class AlertManager: ObservableObject {
    
    // MARK: - Published State
    
    /// Currently playing/queued alert (for UI display)
    @Published private(set) var currentAlert: AlertType?
    
    /// Whether an alert is currently playing
    @Published private(set) var isPlaying: Bool = false
    
    /// Last few alerts for display (most recent first)
    @Published private(set) var recentAlerts: [AlertHistoryEntry] = []
    
    // MARK: - Configuration
    
    /// Maximum alerts to keep in history
    private let maxHistoryCount = 10
    
    /// Global minimum time between any alerts
    private let globalCooldown: TimeInterval = 1.0
    
    // MARK: - Private Properties
    
    private let ttsManager: TTSManager
    private var lastAlertTimes: [AlertType: Date] = [:]
    private var lastGlobalAlertTime: Date?
    private var alertQueue: [AlertRequest] = []
    private var isProcessingQueue = false
    
    private var roadSubscription: AnyCancellable?
    private var driverSubscription: AnyCancellable?
    
    // MARK: - Initialization
    
    init() {
        self.ttsManager = TTSManager()
    }
    
    // MARK: - Setup
    
    /// Subscribe to road pipeline events
    func subscribeToRoadPipeline(_ pipeline: RoadPipeline) {
        roadSubscription = pipeline.hazardEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleRoadHazardEvent(event)
            }
    }
    
    /// Subscribe to driver pipeline events
    func subscribeToDriverPipeline(_ pipeline: DriverPipeline) {
        driverSubscription = pipeline.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleDriverEvent(event)
            }
    }
    
    /// Pre-cache all TTS audio
    func preCacheAudio() async {
        await ttsManager.preCacheAllPhrases()
    }
    
    // MARK: - Event Handlers
    
    private func handleRoadHazardEvent(_ event: RoadHazardEvent) {
        // Get specific alert type based on the detected object
        let alertType = alertTypeForRoadHazard(event)
        
        // Higher severity = higher priority override
        let priorityBoost = event.severity.rawValue * 10
        
        // Create custom phrase with object identification
        let customPhrase: String?
        if let obj = event.triggeringObject {
            let objName = obj.label.rawValue.capitalized
            switch event.type {
            case .closingFast:
                customPhrase = event.severity >= .critical ? 
                    "\(objName) closing fast. Brake now." :
                    "\(objName) getting closer."
            case .vehicleAhead:
                customPhrase = "\(objName) ahead."
            case .pedestrianAhead:
                customPhrase = obj.label == .bicycle ? 
                    "Cyclist ahead. Give space." :
                    "Pedestrian ahead. Slow down."
            case .futurePath:
                customPhrase = "\(objName) entering your path."
            }
        } else {
            customPhrase = nil
        }
        
        let request = AlertRequest(
            type: alertType,
            timestamp: event.timestamp,
            priorityOverride: alertType.priority + priorityBoost,
            phraseOverride: customPhrase
        )
        
        enqueueAlert(request)
    }
    
    private func handleDriverEvent(_ event: DriverEvent) {
        let alertType = alertTypeForDriverEvent(event.type)
        
        // Higher severity = higher priority override
        let priorityBoost = event.severity.rawValue * 10
        
        let request = AlertRequest(
            type: alertType,
            timestamp: event.timestamp,
            priorityOverride: alertType.priority + priorityBoost
        )
        
        enqueueAlert(request)
    }
    
    // MARK: - Manual Alert Trigger
    
    /// Manually trigger an alert (e.g., system ready)
    func triggerAlert(_ type: AlertType) {
        let request = AlertRequest(type: type)
        enqueueAlert(request)
    }
    
    // MARK: - Queue Management
    
    private func enqueueAlert(_ request: AlertRequest) {
        // Check per-alert cooldown
        if let lastTime = lastAlertTimes[request.type] {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < request.cooldown {
                print("[AlertManager] Skipping \(request.type.rawValue): cooldown active (\(String(format: "%.1f", request.cooldown - elapsed))s remaining)")
                return
            }
        }
        
        // Check global cooldown
        if let lastGlobal = lastGlobalAlertTime {
            let elapsed = Date().timeIntervalSince(lastGlobal)
            if elapsed < globalCooldown {
                // Queue for later instead of dropping
                print("[AlertManager] Queueing \(request.type.rawValue): global cooldown active")
            }
        }
        
        // Add to queue (will be sorted by priority)
        alertQueue.append(request)
        alertQueue.sort { $0.priority > $1.priority }  // Higher priority first
        
        // Process queue if not already processing
        if !isProcessingQueue {
            Task {
                await processQueue()
            }
        }
    }
    
    private func processQueue() async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        
        while !alertQueue.isEmpty {
            // Check global cooldown
            if let lastGlobal = lastGlobalAlertTime {
                let elapsed = Date().timeIntervalSince(lastGlobal)
                if elapsed < globalCooldown {
                    // Wait for cooldown
                    let waitTime = globalCooldown - elapsed
                    try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                }
            }
            
            // Get highest priority alert
            guard let request = alertQueue.first else { break }
            alertQueue.removeFirst()
            
            // Double-check per-alert cooldown (might have changed while waiting)
            if let lastTime = lastAlertTimes[request.type] {
                let elapsed = Date().timeIntervalSince(lastTime)
                if elapsed < request.cooldown {
                    continue  // Skip this one
                }
            }
            
            // Play the alert
            await playAlert(request)
        }
        
        isProcessingQueue = false
    }
    
    private func playAlert(_ request: AlertRequest) async {
        // Update state
        currentAlert = request.type
        isPlaying = true
        
        // Record timing
        lastAlertTimes[request.type] = Date()
        lastGlobalAlertTime = Date()
        
        // Add to history
        let entry = AlertHistoryEntry(type: request.type, timestamp: Date())
        recentAlerts.insert(entry, at: 0)
        if recentAlerts.count > maxHistoryCount {
            recentAlerts.removeLast()
        }
        
        print("[AlertManager] Playing: \(request.type.rawValue) - \"\(request.phrase)\"")
        
        // Play warning sound FIRST for road hazard alerts
        if request.type.isRoadHazard {
            // Warning sound disabled for now
            
            // Brief pause after warning sound before speech
            try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2 seconds
        }
        
        // Speak the alert (use custom phrase if provided; pass priority for urgency-based voice)
        await ttsManager.speak(request.type, customPhrase: request.phrase, effectivePriority: request.priority)
        
        // Update state
        currentAlert = nil
        isPlaying = false
    }
    
    // MARK: - Control
    
    /// Stop any current alert and clear queue
    func stopAndClear() {
        alertQueue.removeAll()
        ttsManager.stopSpeaking()
        currentAlert = nil
        isPlaying = false
    }
    
    /// Reset cooldowns (e.g., when restarting)
    func resetCooldowns() {
        lastAlertTimes.removeAll()
        lastGlobalAlertTime = nil
    }
}

// MARK: - Alert History Entry

/// An entry in the alert history
struct AlertHistoryEntry: Identifiable {
    let id = UUID()
    let type: AlertType
    let timestamp: Date
    
    var phrase: String {
        type.phrase
    }
    
    var timeAgo: String {
        let elapsed = Date().timeIntervalSince(timestamp)
        if elapsed < 60 {
            return "\(Int(elapsed))s ago"
        } else {
            return "\(Int(elapsed / 60))m ago"
        }
    }
}
