//
//  AlertPhrases.swift
//  HackBrown
//
//  Fixed set of short alert phrases (~5-8 total) with priority mapping.
//  These phrases are cached as audio for instant playback.
//

import Foundation

// MARK: - Alert Type

/// All alert types with their phrases and priorities
/// Priority: road hazards > distraction > drowsiness
enum AlertType: String, CaseIterable {
    // Road hazards (highest priority)
    case vehicleApproaching = "vehicle_approaching"
    case pedestrianAhead = "pedestrian_ahead"
    case cyclistAhead = "cyclist_ahead"
    
    // Distraction (medium priority)
    case eyesOnRoad = "eyes_on_road"
    case payAttention = "pay_attention"
    
    // Drowsiness (lower priority, but still important)
    case stayAwake = "stay_awake"
    case takeBreak = "take_break"
    
    // System
    case systemReady = "system_ready"
    
    /// The phrase to speak for this alert
    var phrase: String {
        switch self {
        case .vehicleApproaching:
            return "Vehicle approaching"
        case .pedestrianAhead:
            return "Pedestrian ahead"
        case .cyclistAhead:
            return "Cyclist ahead"
        case .eyesOnRoad:
            return "Eyes on the road"
        case .payAttention:
            return "Pay attention"
        case .stayAwake:
            return "Stay awake"
        case .takeBreak:
            return "Consider taking a break"
        case .systemReady:
            return "System ready"
        }
    }
    
    /// Priority level (higher = more important, plays first)
    var priority: Int {
        switch self {
        // Road hazards: highest priority (100-199)
        case .vehicleApproaching:
            return 150
        case .pedestrianAhead:
            return 160  // Pedestrians are most vulnerable
        case .cyclistAhead:
            return 155
            
        // Distraction: medium priority (50-99)
        case .eyesOnRoad:
            return 70
        case .payAttention:
            return 60
            
        // Drowsiness: important but lower priority (30-49)
        case .stayAwake:
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
        case .vehicleApproaching, .pedestrianAhead, .cyclistAhead:
            return 3.0
            
        // Distraction: medium cooldown
        case .eyesOnRoad, .payAttention:
            return 5.0
            
        // Drowsiness: longer cooldown (don't nag too much)
        case .stayAwake, .takeBreak:
            return 10.0
            
        // System: no repeat needed
        case .systemReady:
            return 60.0
        }
    }
    
    /// Whether this is a road hazard alert
    var isRoadHazard: Bool {
        switch self {
        case .vehicleApproaching, .pedestrianAhead, .cyclistAhead:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a distraction alert
    var isDistraction: Bool {
        switch self {
        case .eyesOnRoad, .payAttention:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a drowsiness alert
    var isDrowsiness: Bool {
        switch self {
        case .stayAwake, .takeBreak:
            return true
        default:
            return false
        }
    }
}

// MARK: - Alert Mapping Helpers

/// Maps road hazard events to alert types
func alertTypeForRoadHazard(_ hazardType: RoadHazardType) -> AlertType {
    switch hazardType {
    case .rapidApproach:
        return .vehicleApproaching
    case .pedestrianInPath:
        return .pedestrianAhead
    case .cyclistInPath:
        return .cyclistAhead
    }
}

/// Maps driver events to alert types
func alertTypeForDriverEvent(_ eventType: DriverEventType) -> AlertType {
    switch eventType {
    case .distraction:
        return .eyesOnRoad
    case .drowsiness:
        return .stayAwake
    case .lowAttention:
        return .payAttention
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
