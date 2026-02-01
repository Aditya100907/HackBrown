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
    
    /// Minimum interval (seconds) between alerts in the same category — trims rapid repeat calls
    private let rapidRepeatMaskInterval: TimeInterval = 1.5
    
    // MARK: - Private Properties
    
    private let ttsManager: TTSManager
    private var lastAlertTimes: [AlertType: Date] = [:]
    private var lastPlayedTimeByCategory: [String: Date] = [:]
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
                    "Heads up: \(objName) closing fast. You may want to slow down." :
                    "Heads up: \(objName) getting closer. Consider slowing down."
            case .vehicleAhead:
                customPhrase = "Heads up: \(objName) in path. You may want to slow down."
            case .pedestrianAhead:
                customPhrase = obj.label == .bicycle ? 
                    "Heads up: cyclist in path. Consider giving space." :
                    "Heads up: pedestrian in path. You may want to slow down."
            case .futurePath:
                customPhrase = "Heads up: \(objName) entering your path. Consider slowing down."
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
        // Check per-alert cooldown — don't even queue if we just played this type
        if let lastTime = lastAlertTimes[request.type] {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < request.cooldown {
                print("[AlertManager] Skipping \(request.type.rawValue): cooldown active (\(String(format: "%.1f", request.cooldown - elapsed))s remaining)")
                return
            }
        }
        
        // Mask rapid repeat: same category (road/distraction/drowsiness) in quick succession — trim unnecessary back-to-back calls
        let category = request.type.alertCategory
        if let lastCategoryTime = lastPlayedTimeByCategory[category] {
            let elapsed = Date().timeIntervalSince(lastCategoryTime)
            if elapsed < rapidRepeatMaskInterval {
                return  // Skip this one; we already played something in this category recently
            }
        }
        
        // Mask duplicate: only one request per alert type in the queue (same phrase = blocked; different = allowed)
        if alertQueue.contains(where: { $0.type == request.type }) {
            return
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
        
        // Record timing (per-type and per-category for rapid-repeat mask)
        let now = Date()
        lastAlertTimes[request.type] = now
        lastPlayedTimeByCategory[request.type.alertCategory] = now
        
        // Add to history
        let entry = AlertHistoryEntry(type: request.type, timestamp: Date())
        recentAlerts.insert(entry, at: 0)
        if recentAlerts.count > maxHistoryCount {
            recentAlerts.removeLast()
        }
        
        print("[AlertManager] Playing: \(request.type.rawValue) - \"\(request.phrase)\"")
        
        // Play beepshort.mov immediately (low latency) — user hears it while ElevenLabs/TTS loads
        if request.type.isRoadHazard {
            WarningSoundPlayer.shared.playWarningSound(critical: request.type.isCritical)
        } else {
            WarningSoundPlayer.shared.playWarningSound(critical: false)
        }
        // Start TTS right away (no wait) — beep and TTS request run in parallel for fast response
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
        lastPlayedTimeByCategory.removeAll()
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
