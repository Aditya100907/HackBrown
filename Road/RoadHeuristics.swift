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
    
    /// Raw hazard score (0–1) used to compute severity
    let hazardScore: Float
    
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
    
    /// Assumed system latency (inference + TTS + reaction) in seconds — we project severity forward
    private let latencyCompensationSec: TimeInterval = 0.7
    
    /// Growth rate considered "fast approach" (area/sec)
    private let criticalGrowthThreshold: CGFloat = 0.04
    
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
    
    // MARK: - Hazard Score (0–1)
    
    /// Computes a continuous hazard score from area, path centrality, growth, and object type.
    /// Higher = more urgent. Used for severity + latency compensation.
    private func computeHazardScore(
        detection: DetectedObject,
        growthRate: CGFloat,
        isVulnerableRoadUser: Bool
    ) -> Float {
        // 1. Area factor (0–0.4): larger objects = higher risk
        let areaNorm = min(1, detection.area / largeAreaThreshold)
        let areaScore = Float(areaNorm) * 0.4
        
        // 2. Path centrality (0–0.25): closer to center = more in our path
        let centerX: CGFloat = 0.5
        let centerY: CGFloat = 0.5
        let dx = detection.center.x - centerX
        let dy = detection.center.y - centerY
        let distFromCenter = sqrt(dx * dx + dy * dy)
        let centralityScore = Float(max(0, 1 - distFromCenter * 2)) * 0.25
        
        // 3. Growth/approach factor (0–0.35): faster approach = higher risk
        let growthNorm = min(1, max(0, growthRate / CGFloat(criticalGrowthThreshold)))
        let growthScore = Float(growthNorm) * 0.35
        
        // 4. Object-type weight: pedestrians/cyclists get a boost (vulnerable road users)
        let typeBoost: Float = isVulnerableRoadUser ? 0.15 : 0
        
        // 5. Detection confidence: low confidence slightly reduces score
        let confFactor = 0.7 + 0.3 * detection.confidence
        
        let raw = (areaScore + centralityScore + growthScore + typeBoost) * confFactor
        return min(1, max(0, raw))
    }
    
    /// Project area forward by latency to compensate for system delay
    private func projectedArea(current: CGFloat, growthRate: CGFloat) -> CGFloat {
        current + growthRate * CGFloat(latencyCompensationSec)
    }
    
    /// Map hazard score (0–1) to severity, with conservative bias (round up)
    private func scoreToSeverity(_ score: Float, isClosingFast: Bool) -> HazardSeverity {
        if score >= 0.75 || isClosingFast && score >= 0.5 {
            return .critical
        }
        if score >= 0.5 {
            return .high
        }
        if score >= 0.3 {
            return .medium
        }
        return .low
    }
    
    // MARK: - Hazard Checks
    
    private func checkPedestrian(_ detection: DetectedObject, timestamp: Date) -> RoadHazardEvent? {
        let alertKey = "ped_\(detection.label.rawValue)"
        
        if let lastTime = lastAlertTimes[alertKey], timestamp.timeIntervalSince(lastTime) < alertCooldown {
            return nil
        }
        
        // Pedestrians: area is main factor, no growth tracking needed (they move unpredictably)
        let score = computeHazardScore(detection: detection, growthRate: 0, isVulnerableRoadUser: true)
        let severity = scoreToSeverity(score, isClosingFast: false)
        
        lastAlertTimes[alertKey] = timestamp
        
        let name = detection.label.rawValue.capitalized
        return RoadHazardEvent(
            type: .pedestrianAhead,
            severity: severity,
            timestamp: timestamp,
            description: "\(name) ahead",
            triggeringObject: detection,
            hazardScore: score
        )
    }
    
    private func checkVehicle(_ detection: DetectedObject, timeDelta: TimeInterval, timestamp: Date) -> RoadHazardEvent? {
        let alertKey = "veh_\(detection.label.rawValue)"
        
        if let lastTime = lastAlertTimes[alertKey], timestamp.timeIntervalSince(lastTime) < alertCooldown {
            return nil
        }
        
        var growthRate: CGFloat = 0
        if timeDelta > 0, let tracked = findMatchingTracked(for: detection) {
            let areaDelta = detection.area - tracked.area
            growthRate = areaDelta / CGFloat(timeDelta)
        }
        
        let isApproaching = growthRate > 0.005
        let isClosingFast = growthRate > rapidGrowthThreshold
        let isLarge = detection.area > closeAreaThreshold
        
        guard isLarge || (isApproaching && detection.area > minimumTrackingArea * 3) else {
            return nil
        }
        
        var score = computeHazardScore(detection: detection, growthRate: growthRate, isVulnerableRoadUser: false)
        
        // Latency compensation: boost score when approaching (object will be closer by the time we alert)
        if isApproaching {
            let projArea = projectedArea(current: detection.area, growthRate: growthRate)
            let areaGrowthFactor = min(1.5, projArea / max(0.001, detection.area))
            score = min(1, score * Float(areaGrowthFactor) + 0.1)
        }
        
        let severity = scoreToSeverity(score, isClosingFast: isClosingFast)
        let hazardType: RoadHazardType = isClosingFast ? .closingFast : .vehicleAhead
        
        lastAlertTimes[alertKey] = timestamp
        
        let name = detection.label.rawValue.capitalized
        let desc = hazardType == .closingFast ? "\(name) closing fast" : "\(name) ahead"
        
        return RoadHazardEvent(
            type: hazardType,
            severity: severity,
            timestamp: timestamp,
            description: desc,
            triggeringObject: detection,
            hazardScore: score
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
