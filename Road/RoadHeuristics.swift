//
//  RoadHeuristics.swift
//  HackBrown
//
//  Heuristics for detecting dangerous road situations.
//  Simplified version that actually triggers alerts.
//

import Foundation
import CoreGraphics

// MARK: - Road Hazard Events

/// Types of road hazards we can detect
enum RoadHazardType: String {
    case vehicleAhead = "vehicle_ahead"       // Vehicle in forward path
    case pedestrianAhead = "pedestrian_ahead" // Pedestrian/cyclist in path
    case closingFast = "closing_fast"         // Object approaching rapidly
}

/// A detected road hazard event
struct RoadHazardEvent {
    let type: RoadHazardType
    let severity: HazardSeverity
    let timestamp: Date
    let description: String
    
    /// Object that triggered the hazard
    let triggeringObject: DetectedObject?
    
    /// Specific label of the detected object (for TTS)
    var objectLabel: String {
        triggeringObject?.label.rawValue ?? "obstacle"
    }
}

/// Severity levels for hazards
enum HazardSeverity: Int, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4
    
    static func < (lhs: HazardSeverity, rhs: HazardSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Road Heuristics

/// Analyzes object detections to identify dangerous situations
final class RoadHeuristics {
    
    // MARK: - Configuration
    
    /// Forward path region (where objects ahead matter)
    private let forwardPathXRange: ClosedRange<CGFloat> = 0.1...0.9
    private let forwardPathYRange: ClosedRange<CGFloat> = 0.1...0.95
    
    /// Minimum area growth rate (per second) for rapid approach
    private let rapidGrowthThreshold: CGFloat = 0.02
    
    /// Minimum object area to consider (very small = 0.5% of frame)
    private let minimumTrackingArea: CGFloat = 0.003
    
    /// Area threshold for "close" objects (5% of frame)
    private let closeAreaThreshold: CGFloat = 0.05
    
    /// Large object threshold (10% of frame)
    private let largeAreaThreshold: CGFloat = 0.10
    
    // MARK: - State
    
    /// Tracked objects from previous frame
    private var trackedObjects: [TrackedObject] = []
    
    /// Last analysis timestamp
    private var lastAnalysisTime: Date?
    
    /// Cooldown tracking for alerts
    private var lastAlertTimes: [String: Date] = [:]
    private let alertCooldown: TimeInterval = 4.0
    
    // MARK: - Tracked Object
    
    private struct TrackedObject {
        let label: ObjectLabel
        let center: CGPoint
        let area: CGFloat
        let timestamp: Date
    }
    
    // MARK: - Analysis
    
    /// Analyze detections and return hazard events
    func analyze(detections: [DetectedObject], timestamp: Date = Date()) -> [RoadHazardEvent] {
        var events: [RoadHazardEvent] = []
        
        // Calculate time delta
        let timeDelta: TimeInterval
        if let lastTime = lastAnalysisTime {
            timeDelta = timestamp.timeIntervalSince(lastTime)
        } else {
            timeDelta = 0
        }
        
        // Log detections for debugging
        if !detections.isEmpty {
            print("[RoadHeuristics] Analyzing \(detections.count) detections")
        }
        
        // Check each detection
        for detection in detections {
            // Skip very small objects
            guard detection.area >= minimumTrackingArea else { 
                continue 
            }
            
            // Check if in forward path
            guard isInForwardPath(detection) else { 
                continue 
            }
            
            // Check for pedestrian/cyclist (always important)
            if detection.label.isVulnerableRoadUser {
                if let event = checkPedestrian(detection, timestamp: timestamp) {
                    events.append(event)
                }
            }
            // Check for vehicle
            else if detection.label.isVehicle {
                if let event = checkVehicle(detection, timeDelta: timeDelta, timestamp: timestamp) {
                    events.append(event)
                }
            }
        }
        
        // Update tracked objects for next frame
        trackedObjects = detections.map { 
            TrackedObject(label: $0.label, center: $0.center, area: $0.area, timestamp: timestamp)
        }
        lastAnalysisTime = timestamp
        
        if !events.isEmpty {
            print("[RoadHeuristics] Generated \(events.count) hazard events")
        }
        
        return events
    }
    
    /// Reset tracking state
    func reset() {
        trackedObjects.removeAll()
        lastAnalysisTime = nil
        lastAlertTimes.removeAll()
    }
    
    // MARK: - Hazard Checks
    
    private func checkPedestrian(_ detection: DetectedObject, timestamp: Date) -> RoadHazardEvent? {
        let alertKey = "ped_\(detection.label.rawValue)"
        
        // Check cooldown
        if let lastTime = lastAlertTimes[alertKey], timestamp.timeIntervalSince(lastTime) < alertCooldown {
            return nil
        }
        
        // Any pedestrian/cyclist in path is concerning
        let severity: HazardSeverity
        if detection.area > largeAreaThreshold {
            severity = .critical
        } else if detection.area > closeAreaThreshold {
            severity = .high
        } else {
            severity = .medium
        }
        
        lastAlertTimes[alertKey] = timestamp
        
        let name = detection.label.rawValue.capitalized
        return RoadHazardEvent(
            type: .pedestrianAhead,
            severity: severity,
            timestamp: timestamp,
            description: "\(name) ahead",
            triggeringObject: detection
        )
    }
    
    private func checkVehicle(_ detection: DetectedObject, timeDelta: TimeInterval, timestamp: Date) -> RoadHazardEvent? {
        let alertKey = "veh_\(detection.label.rawValue)"
        
        // Check cooldown
        if let lastTime = lastAlertTimes[alertKey], timestamp.timeIntervalSince(lastTime) < alertCooldown {
            return nil
        }
        
        // Check if this vehicle is approaching (area growing)
        var isApproaching = false
        var growthRate: CGFloat = 0
        
        if timeDelta > 0, let tracked = findMatchingTracked(for: detection) {
            let areaDelta = detection.area - tracked.area
            growthRate = areaDelta / CGFloat(timeDelta)
            isApproaching = growthRate > 0.005  // Any positive growth
        }
        
        // Determine if we should alert
        // Alert if: large object OR approaching object
        let isLarge = detection.area > closeAreaThreshold
        let isClosingFast = growthRate > rapidGrowthThreshold
        
        // Only alert for significant objects
        guard isLarge || (isApproaching && detection.area > minimumTrackingArea * 3) else {
            return nil
        }
        
        // Determine severity and type
        let severity: HazardSeverity
        let hazardType: RoadHazardType
        
        if isClosingFast && detection.area > closeAreaThreshold {
            severity = .critical
            hazardType = .closingFast
        } else if isClosingFast {
            severity = .high
            hazardType = .closingFast
        } else if detection.area > largeAreaThreshold {
            severity = .high
            hazardType = .vehicleAhead
        } else if isLarge {
            severity = .medium
            hazardType = .vehicleAhead
        } else {
            return nil  // Not significant enough
        }
        
        lastAlertTimes[alertKey] = timestamp
        
        let name = detection.label.rawValue.capitalized
        let desc = hazardType == .closingFast ? "\(name) closing fast" : "\(name) ahead"
        
        return RoadHazardEvent(
            type: hazardType,
            severity: severity,
            timestamp: timestamp,
            description: desc,
            triggeringObject: detection
        )
    }
    
    // MARK: - Helpers
    
    private func isInForwardPath(_ detection: DetectedObject) -> Bool {
        let center = detection.center
        return forwardPathXRange.contains(center.x) && forwardPathYRange.contains(center.y)
    }
    
    private func findMatchingTracked(for detection: DetectedObject) -> TrackedObject? {
        // Find a tracked object with same label and close position
        let maxDistance: CGFloat = 0.3
        
        return trackedObjects.first { tracked in
            guard tracked.label == detection.label else { return false }
            
            let dx = abs(tracked.center.x - detection.center.x)
            let dy = abs(tracked.center.y - detection.center.y)
            let distance = sqrt(dx * dx + dy * dy)
            
            return distance < maxDistance
        }
    }
}
