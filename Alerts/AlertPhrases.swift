//
//  AlertPhrases.swift
//  HackBrown
//
//  Alert types with phrases and priority mapping.
//  Road hazard alerts include specific object identification.
//

import Foundation
import AVFoundation

// MARK: - Alert Type

/// All alert types with their phrases and priorities
/// Priority: road hazards > distraction > drowsiness
enum AlertType: String, CaseIterable {
    // Road hazards (highest priority) - with specific object identification
    case carAhead = "car_ahead"
    case truckAhead = "truck_ahead"
    case pedestrianAhead = "pedestrian_ahead"
    case cyclistAhead = "cyclist_ahead"
    case vehicleClosing = "vehicle_closing"
    case obstacleAhead = "obstacle_ahead"  // Generic fallback
    case closingFast = "closing_fast"      // Generic closing alert
    
    // Distraction (medium priority) — DRIVER_DISTRACTED
    case eyesUp = "eyes_up"
    case watchRoad = "watch_road"
    case keepEyesOnRoad = "keep_eyes_on_road"
    
    // Drowsiness (lower priority) — DRIVER_DROWSY
    case drowsy = "drowsy"
    case takeBreak = "take_break"
    case drowsyBlinks = "drowsy_blinks"  // 3 consecutive long blinks detected
    
    // System
    case systemReady = "system_ready"
    
    /// The phrase to speak for this alert
    var phrase: String {
        switch self {
        case .carAhead:
            return "Car ahead."
        case .truckAhead:
            return "Truck ahead."
        case .pedestrianAhead:
            return "Pedestrian ahead. Slow down."
        case .cyclistAhead:
            return "Cyclist ahead. Give space."
        case .vehicleClosing:
            return "Vehicle closing. Brake."
        case .obstacleAhead:
            return "Obstacle ahead."
        case .closingFast:
            return "Closing fast. Brake now."
        case .eyesUp:
            return "Eyes up."
        case .watchRoad:
            return "Watch the road."
        case .keepEyesOnRoad:
            return "Keep your eyes on the road."
        case .drowsy:
            return "You seem drowsy."
        case .takeBreak:
            return "Consider taking a break."
        case .drowsyBlinks:
            return "You appear drowsy. Multiple slow blinks detected. Consider taking a break."
        case .systemReady:
            return "System ready."
        }
    }
    
    /// Priority level (higher = more important, plays first)
    var priority: Int {
        switch self {
        // Road hazards: highest priority (100-199)
        case .closingFast, .vehicleClosing:
            return 180  // Most urgent - closing fast
        case .pedestrianAhead, .cyclistAhead:
            return 170  // Vulnerable road users
        case .carAhead, .truckAhead:
            return 155
        case .obstacleAhead:
            return 150
            
        // Distraction: medium priority (50-99)
        case .eyesUp:
            return 70
        case .keepEyesOnRoad:
            return 68
        case .watchRoad:
            return 65
            
        // Drowsiness: important but lower priority (30-49)
        case .drowsy:
            return 45
        case .drowsyBlinks:
            return 48  // Slightly higher priority than generic drowsy
        case .takeBreak:
            return 40
            
        // System: lowest (0-29)
        case .systemReady:
            return 10
        }
    }
    
    /// Default cooldown for this alert type (seconds)
    var defaultCooldown: TimeInterval {
        switch self {
        // Road hazards: longer cooldown to avoid annoying repetition
        case .closingFast, .vehicleClosing:
            return 4.0
        case .pedestrianAhead, .cyclistAhead:
            return 5.0
        case .carAhead, .truckAhead, .obstacleAhead:
            return 6.0
            
        // Distraction: medium cooldown
        case .eyesUp, .watchRoad, .keepEyesOnRoad:
            return 5.0
            
        // Drowsiness: longer cooldown (don't nag too much)
        case .drowsy, .takeBreak, .drowsyBlinks:
            return 15.0  // Longer cooldown for drowsiness alerts
            
        // System: no repeat needed
        case .systemReady:
            return 60.0
        }
    }
    
    /// Whether this is a road hazard alert (plays warning sound first)
    var isRoadHazard: Bool {
        switch self {
        case .carAhead, .truckAhead, .pedestrianAhead, .cyclistAhead, 
             .vehicleClosing, .obstacleAhead, .closingFast:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a critical alert (plays louder/longer warning sound)
    var isCritical: Bool {
        switch self {
        case .closingFast, .vehicleClosing, .pedestrianAhead, .cyclistAhead:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a distraction alert
    var isDistraction: Bool {
        switch self {
        case .eyesUp, .watchRoad, .keepEyesOnRoad:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a drowsiness alert
    var isDrowsiness: Bool {
        switch self {
        case .drowsy, .takeBreak, .drowsyBlinks:
            return true
        default:
            return false
        }
    }
}

// MARK: - Alert Mapping Helpers

/// Maps road hazard events to alert types with specific object identification
func alertTypeForRoadHazard(_ event: RoadHazardEvent) -> AlertType {
    // Get specific object label
    let objectLabel = event.triggeringObject?.label
    
    switch event.type {
    case .closingFast:
        // Closing fast is always urgent regardless of object type
        if event.severity >= .critical {
            return .closingFast
        } else {
            return .vehicleClosing
        }

    case .futurePath:
        // Future path prediction: use a proactive closing warning
        switch objectLabel {
        case .person:
            return .pedestrianAhead
        case .bicycle:
            return .cyclistAhead
        case .car, .truck, .bus, .motorcycle:
            return .vehicleClosing
        default:
            return .obstacleAhead
        }
        
    case .vehicleAhead:
        // Identify specific vehicle type
        switch objectLabel {
        case .car:
            return .carAhead
        case .truck:
            return .truckAhead
        case .bus:
            return .truckAhead  // Treat bus like truck
        case .motorcycle:
            return .carAhead   // Treat motorcycle like car for alerts
        default:
            return .obstacleAhead
        }
        
    case .pedestrianAhead:
        // Pedestrian or cyclist
        switch objectLabel {
        case .person:
            return .pedestrianAhead
        case .bicycle:
            return .cyclistAhead
        default:
            return .pedestrianAhead
        }
    }
}

/// Maps driver events to alert types
func alertTypeForDriverEvent(_ eventType: DriverEventType) -> AlertType {
    switch eventType {
    case .distraction:
        return .keepEyesOnRoad
    case .drowsiness:
        return .drowsy
    case .repeatedDrowsyBlinks:
        return .drowsyBlinks
    case .lowAttention:
        return .keepEyesOnRoad
    case .highFatigue:
        return .takeBreak
    }
}

// MARK: - Alert Request

/// A request to play an alert
struct AlertRequest: Comparable {
    let type: AlertType
    let timestamp: Date
    
    /// Custom priority override (if nil, uses type's default priority)
    let priorityOverride: Int?
    
    /// Custom phrase override (for dynamic messages)
    let phraseOverride: String?
    
    var priority: Int {
        priorityOverride ?? type.priority
    }
    
    var phrase: String {
        phraseOverride ?? type.phrase
    }
    
    var cooldown: TimeInterval {
        type.defaultCooldown
    }
    
    init(type: AlertType, timestamp: Date = Date(), priorityOverride: Int? = nil, phraseOverride: String? = nil) {
        self.type = type
        self.timestamp = timestamp
        self.priorityOverride = priorityOverride
        self.phraseOverride = phraseOverride
    }
    
    // Comparable: higher priority comes first
    static func < (lhs: AlertRequest, rhs: AlertRequest) -> Bool {
        lhs.priority < rhs.priority
    }
}

// MARK: - Warning Sound Player

/// Plays a warning sound before TTS alerts
class WarningSoundPlayer {
    static let shared = WarningSoundPlayer()
    
    private var audioPlayer: AVAudioPlayer?
    
    private init() {}
    
    /// Play a warning beep sound
    /// - Parameter critical: If true, plays a louder/more urgent sound
    func playWarningSound(critical: Bool = false) {
        // Use system sound for immediate playback
        let soundID: SystemSoundID = critical ? 1521 : 1519  // Different beep sounds
        AudioServicesPlaySystemSound(soundID)
        
        // Also add haptic feedback for critical alerts
        if critical {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }
    }
}

// Need to import UIKit for haptic feedback
import UIKit
