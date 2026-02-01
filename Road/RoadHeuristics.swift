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
    case futurePath = "future_path"           // Object predicted to enter path soon
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

    /// Prediction horizon (seconds) for momentum-based forecasting
    private let predictionHorizon: TimeInterval = 1.2

    /// Minimum normalized speed (per second) before considering prediction
    private let minPredictionSpeed: CGFloat = 0.04

    /// Allow objects slightly outside the forward path to be considered for prediction
    private let nearPathMargin: CGFloat = 0.12

    /// Maximum time to keep motion history
    private let maxTrackAge: TimeInterval = 1.8

    /// Maximum motion samples to retain per track
    private let maxTrackSamples: Int = 5

    /// Area influence on predicted displacement (larger objects get scaled)
    private let areaMomentumWeight: CGFloat = 6.0

    /// Cap on the area-based boost applied to displacement
    private let maxAreaMomentumBoost: CGFloat = 2.5
    
    // MARK: - State
    
    /// Motion tracks maintained across frames
    private var motionTracks: [MotionTrack] = []
    
    /// Last analysis timestamp
    private var lastAnalysisTime: Date?
    
    /// Cooldown tracking for alerts
    private var lastAlertTimes: [String: Date] = [:]
    private let alertCooldown: TimeInterval = 4.0
    
    // MARK: - Tracked Object

    private struct MotionSample {
        let center: CGPoint
        let area: CGFloat
        let timestamp: Date
    }

    private struct MotionTrack {
        let id = UUID()
        let label: ObjectLabel
        var samples: [MotionSample]

        var lastSample: MotionSample? {
            samples.last
        }

        mutating func add(center: CGPoint, area: CGFloat, timestamp: Date, maxSamples: Int) {
            samples.append(MotionSample(center: center, area: area, timestamp: timestamp))
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
        }

        /// Weighted average velocity (normalized units per second), emphasizing recent motion.
        func weightedVelocity() -> CGPoint? {
            guard samples.count >= 2 else { return nil }

            var weighted = CGPoint.zero
            var totalWeight: CGFloat = 0

            for index in 1..<samples.count {
                let prev = samples[index - 1]
                let curr = samples[index]
                let dt = CGFloat(curr.timestamp.timeIntervalSince(prev.timestamp))
                guard dt > 0 else { continue }

                let velocity = CGPoint(
                    x: (curr.center.x - prev.center.x) / dt,
                    y: (curr.center.y - prev.center.y) / dt
                )

                // Recent segments get higher weight (linear ramp)
                let recency = CGFloat(index) / CGFloat(samples.count)
                let weight = 0.6 + recency

                weighted.x += velocity.x * weight
                weighted.y += velocity.y * weight
                totalWeight += weight
            }

            guard totalWeight > 0 else { return nil }
            return CGPoint(x: weighted.x / totalWeight, y: weighted.y / totalWeight)
        }
    }
    
    // MARK: - Analysis
    
    struct AnalysisResult {
        let events: [RoadHazardEvent]
        let motionVectors: [UUID: CGPoint]
    }
    
    /// Analyze detections and return hazard events + motion vectors
    func analyze(detections: [DetectedObject], timestamp: Date = Date()) -> AnalysisResult {
        var events: [RoadHazardEvent] = []
        var motionVectors: [UUID: CGPoint] = [:]
        
        // Remove stale tracks and compute frame delta
        cleanupTracks(at: timestamp)
        let timeDelta: TimeInterval = lastAnalysisTime.map { timestamp.timeIntervalSince($0) } ?? 0
        
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

            let matchedIndex = matchTrack(for: detection)
            let matchedTrack = matchedIndex.flatMap { motionTracks[$0] }
            let velocity = matchedTrack?.weightedVelocity()
            let growthRate = calculateGrowthRate(
                for: detection,
                track: matchedTrack,
                timestamp: timestamp,
                fallbackDelta: timeDelta
            )

            let isCurrentlyInPath = isInForwardPath(detection)

            // Predictive hazard: object likely to enter path soon
            if let event = checkPredictedPath(
                detection,
                track: matchedTrack,
                velocity: velocity,
                growthRate: growthRate,
                timestamp: timestamp,
                alreadyInPath: isCurrentlyInPath
            ) {
                events.append(event)
            }

            // Store motion vector for overlay if strong enough and object is sizable
            if let velocity = velocity {
                let speed = hypot(velocity.x, velocity.y)
                if speed >= minPredictionSpeed, detection.area > minimumTrackingArea * 2 {
                    motionVectors[detection.id] = velocity
                }
            }

            // For in-path objects, run existing checks
            guard isCurrentlyInPath else {
                updateTrack(with: detection, timestamp: timestamp, matchedIndex: matchedIndex)
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
                if let event = checkVehicle(detection, growthRate: growthRate, timestamp: timestamp) {
                    events.append(event)
                }
            }

            updateTrack(with: detection, timestamp: timestamp, matchedIndex: matchedIndex)
        }
        
        lastAnalysisTime = timestamp
        
        if !events.isEmpty {
            print("[RoadHeuristics] Generated \(events.count) hazard events")
        }
        
        return AnalysisResult(events: events, motionVectors: motionVectors)
    }
    
    /// Reset tracking state
    func reset() {
        motionTracks.removeAll()
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
    
    private func checkVehicle(_ detection: DetectedObject, growthRate: CGFloat, timestamp: Date) -> RoadHazardEvent? {
        let alertKey = "veh_\(detection.label.rawValue)"
        
        // Check cooldown
        if let lastTime = lastAlertTimes[alertKey], timestamp.timeIntervalSince(lastTime) < alertCooldown {
            return nil
        }
        
        // Check if this vehicle is approaching (area growing)
        let isApproaching = growthRate > 0.005  // Any positive growth
        
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
    
    private func checkPredictedPath(
        _ detection: DetectedObject,
        track: MotionTrack?,
        velocity: CGPoint?,
        growthRate: CGFloat,
        timestamp: Date,
        alreadyInPath: Bool
    ) -> RoadHazardEvent? {
        // Only predict for vehicles and VRUs near the path
        guard detection.label.isVehicle || detection.label.isVulnerableRoadUser else { return nil }
        guard isNearForwardPath(detection) else { return nil }
        guard let velocity = velocity else { return nil }

        let speed = hypot(velocity.x, velocity.y)
        guard speed >= minPredictionSpeed else { return nil }

        let areaBoost = min(1 + detection.area * areaMomentumWeight, maxAreaMomentumBoost)
        let displacement = CGPoint(
            x: velocity.x * CGFloat(predictionHorizon) * areaBoost,
            y: velocity.y * CGFloat(predictionHorizon) * areaBoost
        )

        let predictedCenter = CGPoint(
            x: detection.center.x + displacement.x,
            y: detection.center.y + displacement.y
        )

        let predictedArea = detection.area + growthRate * CGFloat(predictionHorizon)
        let entersPath = isInForwardPath(predictedCenter)
        let gettingCloser = predictedArea > detection.area * 1.02 || displacement.y > 0.01

        // Skip if already inside path and will remain small
        guard entersPath && gettingCloser else { return nil }
        if alreadyInPath && detection.area > closeAreaThreshold {
            return nil
        }

        let severity: HazardSeverity
        if predictedArea > closeAreaThreshold || displacement.y > 0.08 {
            severity = .high
        } else {
            severity = .medium
        }

        let alertKey = "pred_\(detection.label.rawValue)"
        if let lastTime = lastAlertTimes[alertKey], timestamp.timeIntervalSince(lastTime) < alertCooldown {
            return nil
        }
        lastAlertTimes[alertKey] = timestamp

        let desc = "\(detection.label.rawValue.capitalized) entering path"
        return RoadHazardEvent(
            type: .futurePath,
            severity: severity,
            timestamp: timestamp,
            description: desc,
            triggeringObject: detection
        )
    }
    
    // MARK: - Helpers
    
    private func isInForwardPath(_ detection: DetectedObject) -> Bool {
        isInForwardPath(detection.center)
    }

    private func isInForwardPath(_ center: CGPoint) -> Bool {
        return forwardPathXRange.contains(center.x) && forwardPathYRange.contains(center.y)
    }
    
    private func isNearForwardPath(_ detection: DetectedObject) -> Bool {
        let expandedX = (forwardPathXRange.lowerBound - nearPathMargin)...(forwardPathXRange.upperBound + nearPathMargin)
        let expandedY = (forwardPathYRange.lowerBound - nearPathMargin)...(forwardPathYRange.upperBound + nearPathMargin)
        let center = detection.center
        return expandedX.contains(center.x) && expandedY.contains(center.y)
    }

    private func cleanupTracks(at timestamp: Date) {
        motionTracks.removeAll { track in
            guard let last = track.lastSample else { return true }
            return timestamp.timeIntervalSince(last.timestamp) > maxTrackAge
        }
    }

    private func matchTrack(for detection: DetectedObject) -> Int? {
        let maxDistance: CGFloat = 0.3
        let center = detection.center

        var bestIndex: Int?
        var bestDistance = maxDistance

        for (index, track) in motionTracks.enumerated() where track.label == detection.label {
            guard let last = track.lastSample else { continue }
            let dx = center.x - last.center.x
            let dy = center.y - last.center.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    private func updateTrack(with detection: DetectedObject, timestamp: Date, matchedIndex: Int?) {
        if let index = matchedIndex {
            motionTracks[index].add(center: detection.center, area: detection.area, timestamp: timestamp, maxSamples: maxTrackSamples)
        } else {
            let sample = MotionSample(center: detection.center, area: detection.area, timestamp: timestamp)
            motionTracks.append(MotionTrack(label: detection.label, samples: [sample]))
        }
    }

    private func calculateGrowthRate(
        for detection: DetectedObject,
        track: MotionTrack?,
        timestamp: Date,
        fallbackDelta: TimeInterval
    ) -> CGFloat {
        if let last = track?.lastSample {
            let dt = CGFloat(timestamp.timeIntervalSince(last.timestamp))
            guard dt > 0 else { return 0 }
            return (detection.area - last.area) / dt
        }

        guard fallbackDelta > 0 else { return 0 }
        return (detection.area) / CGFloat(fallbackDelta)
    }
}
