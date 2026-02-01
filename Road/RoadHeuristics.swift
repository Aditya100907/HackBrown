//
//  RoadHeuristics.swift
//  HackBrown
//
//  Simple, reliable heuristics for detecting dangerous road situations.
//  - Car ahead rapidly "growing" in frame → rapid closing / braking ahead
//  - Pedestrian appearing in forward path region
//

import Foundation
import CoreGraphics

// MARK: - Road Hazard Events (per PROJECT_SPEC)

/// Types of road hazards we can detect
/// OBSTACLE_AHEAD: vehicle or person in forward scene
/// CLOSING_FAST: rapid growth of leading vehicle's bounding box
enum RoadHazardType: String {
    case obstacleAhead = "obstacle_ahead"  // Vehicle or person detected in forward scene
    case closingFast = "closing_fast"      // Vehicle ahead rapidly growing (braking ahead)
}

/// A detected road hazard event
struct RoadHazardEvent {
    let type: RoadHazardType
    let severity: HazardSeverity
    let timestamp: Date
    let description: String
    
    /// Object that triggered the hazard (if any)
    let triggeringObject: DetectedObject?
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
    
    /// Forward path region (center portion of frame where pedestrians are dangerous)
    /// Normalized coordinates: x range and y range
    private let forwardPathXRange: ClosedRange<CGFloat> = 0.2...0.8
    private let forwardPathYRange: ClosedRange<CGFloat> = 0.3...0.9
    
    /// Minimum area growth rate (per second) to trigger rapid approach alert
    /// e.g., 0.1 means object area increased by 10% of frame area per second
    private let rapidGrowthThreshold: CGFloat = 0.05
    
    /// Minimum object area to track (ignore very small detections)
    private let minimumTrackingArea: CGFloat = 0.01
    
    /// Maximum time between frames to consider for growth calculation
    private let maxTrackingInterval: TimeInterval = 0.5
    
    // MARK: - State
    
    /// Tracked objects from previous frame (for growth calculation)
    private var trackedObjects: [TrackedObject] = []
    
    /// Last analysis timestamp
    private var lastAnalysisTime: Date?
    
    // MARK: - Analysis
    
    /// Analyze detections and return any hazard events
    /// - Parameters:
    ///   - detections: Current frame detections
    ///   - timestamp: Frame timestamp
    /// - Returns: Array of hazard events (may be empty)
    func analyze(detections: [DetectedObject], timestamp: Date = Date()) -> [RoadHazardEvent] {
        var events: [RoadHazardEvent] = []
        
        // Calculate time delta
        let timeDelta: TimeInterval
        if let lastTime = lastAnalysisTime {
            timeDelta = timestamp.timeIntervalSince(lastTime)
        } else {
            timeDelta = 0
        }
        
        // Check each detection
        for detection in detections {
            // Skip small objects
            guard detection.area >= minimumTrackingArea else { continue }
            
            // OBSTACLE_AHEAD: vehicle or person in forward scene (per spec)
            if detection.label.isVehicle || detection.label.isVulnerableRoadUser {
                if let event = checkObstacleAhead(detection, timestamp: timestamp) {
                    events.append(event)
                }
            }
            
            // CLOSING_FAST: rapid growth of leading vehicle (per spec)
            if detection.label.isVehicle && timeDelta > 0 && timeDelta < maxTrackingInterval {
                if let event = checkClosingFast(detection, timeDelta: timeDelta, timestamp: timestamp) {
                    events.append(event)
                }
            }
        }
        
        // Update tracking state
        updateTrackedObjects(detections: detections, timestamp: timestamp)
        lastAnalysisTime = timestamp
        
        return events
    }
    
    /// Reset tracking state (e.g., when switching sources)
    func reset() {
        trackedObjects.removeAll()
        lastAnalysisTime = nil
    }
    
    // MARK: - Hazard Checks
    
    /// OBSTACLE_AHEAD: vehicle or person detected in forward scene (per spec)
    private func checkObstacleAhead(_ detection: DetectedObject, timestamp: Date) -> RoadHazardEvent? {
        let center = detection.center
        
        // Check if center is in forward path region
        guard forwardPathXRange.contains(center.x),
              forwardPathYRange.contains(center.y) else {
            return nil
        }
        
        // Determine severity based on position and size
        let severity: HazardSeverity
        let verticalPosition = center.y
        
        if verticalPosition > 0.7 && detection.area > 0.05 {
            // Large object in lower portion of frame = very close
            severity = .critical
        } else if verticalPosition > 0.5 {
            severity = .high
        } else {
            severity = .medium
        }
        
        let description = "\(detection.label.rawValue.capitalized) in forward scene"
        
        return RoadHazardEvent(
            type: .obstacleAhead,
            severity: severity,
            timestamp: timestamp,
            description: description,
            triggeringObject: detection
        )
    }
    
    /// CLOSING_FAST: rapid growth of leading vehicle's bounding box (per spec)
    private func checkClosingFast(_ detection: DetectedObject, timeDelta: TimeInterval, timestamp: Date) -> RoadHazardEvent? {
        // Find matching tracked object from previous frame
        guard let tracked = findMatchingTrackedObject(for: detection) else {
            return nil
        }
        
        // Calculate growth rate (area change per second)
        let areaDelta = detection.area - tracked.area
        let growthRate = areaDelta / CGFloat(timeDelta)
        
        // Only alert on positive growth (approaching, not receding)
        guard growthRate > rapidGrowthThreshold else {
            return nil
        }
        
        // Determine severity based on growth rate and current size
        let severity: HazardSeverity
        if growthRate > rapidGrowthThreshold * 3 || detection.area > 0.3 {
            severity = .critical
        } else if growthRate > rapidGrowthThreshold * 2 {
            severity = .high
        } else {
            severity = .medium
        }
        
        return RoadHazardEvent(
            type: .closingFast,
            severity: severity,
            timestamp: timestamp,
            description: "Vehicle ahead closing fast",
            triggeringObject: detection
        )
    }
    
    // MARK: - Object Tracking
    
    /// Simple tracked object for frame-to-frame comparison
    private struct TrackedObject {
        let label: ObjectLabel
        let center: CGPoint
        let area: CGFloat
        let timestamp: Date
    }
    
    /// Find a matching tracked object from the previous frame
    private func findMatchingTrackedObject(for detection: DetectedObject) -> TrackedObject? {
        // Simple matching: same label and close center position
        let maxCenterDistance: CGFloat = 0.2  // Max center movement between frames
        
        return trackedObjects.first { tracked in
            guard tracked.label == detection.label else { return false }
            
            let dx = abs(tracked.center.x - detection.center.x)
            let dy = abs(tracked.center.y - detection.center.y)
            let distance = sqrt(dx * dx + dy * dy)
            
            return distance < maxCenterDistance
        }
    }
    
    /// Update tracked objects for next frame
    private func updateTrackedObjects(detections: [DetectedObject], timestamp: Date) {
        trackedObjects = detections.map { detection in
            TrackedObject(
                label: detection.label,
                center: detection.center,
                area: detection.area,
                timestamp: timestamp
            )
        }
    }
}
