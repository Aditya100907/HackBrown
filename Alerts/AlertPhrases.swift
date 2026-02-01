//
//  AlertPhrases.swift
//  HackBrown
//
//  Fixed set of short alert phrases (~5-8 total) with priority mapping.
//  These phrases are cached as audio for instant playback.
//

import Foundation

// MARK: - Alert Type

/// All alert types with their phrases and priorities (per PROJECT_SPEC)
/// Priority: road hazards > distraction > drowsiness
/// Spec phrases: "Eyes up.", "Watch the road.", "You seem drowsy.", "Obstacle ahead.", "Closing fast."
enum AlertType: String, CaseIterable {
    // Road hazards (highest priority) — OBSTACLE_AHEAD, CLOSING_FAST
    case obstacleAhead = "obstacle_ahead"
    case closingFast = "closing_fast"
    
    // Distraction (medium priority) — DRIVER_DISTRACTED
    case eyesUp = "eyes_up"
    case watchRoad = "watch_road"
    
    // Drowsiness (lower priority) — DRIVER_DROWSY
    case drowsy = "drowsy"
    case takeBreak = "take_break"
    
    // System
    case systemReady = "system_ready"
    
    /// The phrase to speak for this alert (per spec: ~5-8 short phrases)
    var phrase: String {
        switch self {
        case .obstacleAhead:
            return "Obstacle ahead."
        case .closingFast:
            return "Closing fast."
        case .eyesUp:
            return "Eyes up."
        case .watchRoad:
            return "Watch the road."
        case .drowsy:
            return "You seem drowsy."
        case .takeBreak:
            return "Consider taking a break."
        case .systemReady:
            return "System ready."
        }
    }
    
    /// Priority level (higher = more important, plays first)
    var priority: Int {
        switch self {
        // Road hazards: highest priority (100-199)
        case .obstacleAhead:
            return 160
        case .closingFast:
            return 155
            
        // Distraction: medium priority (50-99)
        case .eyesUp:
            return 70
        case .watchRoad:
            return 65
            
        // Drowsiness: important but lower priority (30-49)
        case .drowsy:
            return 45
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
        // Road hazards: shorter cooldown (can repeat more often)
        case .obstacleAhead, .closingFast:
            return 3.0
            
        // Distraction: medium cooldown
        case .eyesUp, .watchRoad:
            return 5.0
            
        // Drowsiness: longer cooldown (don't nag too much)
        case .drowsy, .takeBreak:
            return 10.0
            
        // System: no repeat needed
        case .systemReady:
            return 60.0
        }
    }
    
    /// Whether this is a road hazard alert
    var isRoadHazard: Bool {
        switch self {
        case .obstacleAhead, .closingFast:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a distraction alert
    var isDistraction: Bool {
        switch self {
        case .eyesUp, .watchRoad:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a drowsiness alert
    var isDrowsiness: Bool {
        switch self {
        case .drowsy, .takeBreak:
            return true
        default:
            return false
        }
    }
}

// MARK: - Alert Mapping Helpers

/// Maps road hazard events to alert types (spec: OBSTACLE_AHEAD, CLOSING_FAST)
func alertTypeForRoadHazard(_ hazardType: RoadHazardType) -> AlertType {
    switch hazardType {
    case .obstacleAhead:
        return .obstacleAhead
    case .closingFast:
        return .closingFast
    }
}

/// Maps driver events to alert types (spec: DRIVER_DISTRACTED, DRIVER_DROWSY)
func alertTypeForDriverEvent(_ eventType: DriverEventType) -> AlertType {
    switch eventType {
    case .distraction:
        return .eyesUp
    case .drowsiness:
        return .drowsy
    case .lowAttention:
        return .watchRoad
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
    
    var priority: Int {
        priorityOverride ?? type.priority
    }
    
    var phrase: String {
        type.phrase
    }
    
    var cooldown: TimeInterval {
        type.defaultCooldown
    }
    
    init(type: AlertType, timestamp: Date = Date(), priorityOverride: Int? = nil) {
        self.type = type
        self.timestamp = timestamp
        self.priorityOverride = priorityOverride
    }
    
    // Comparable: higher priority comes first
    static func < (lhs: AlertRequest, rhs: AlertRequest) -> Bool {
        lhs.priority < rhs.priority
    }
}
