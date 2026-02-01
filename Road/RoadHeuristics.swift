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
    
    /// Forward path region (where objects ahead matter) — used for "caution" / vehicle ahead
    private let forwardPathXRange: ClosedRange<CGFloat> = 0.1...0.9
    private let forwardPathYRange: ClosedRange<CGFloat> = 0.1...0.95

    /// Narrow center strip = "in our lane". Only objects here get high-risk / closing-fast.
    private let centerLaneXRange: ClosedRange<CGFloat> = 0.35...0.65
    
    /// Minimum area growth rate (per second) for rapid approach
    private let rapidGrowthThreshold: CGFloat = 0.02
    
    /// Growth rate below this = object receding (passing or moving away). No closing/urgent alerts.
    private let recedingGrowthThreshold: CGFloat = -0.005
    
    /// Velocity.y below this (normalized/sec) = object moving away from us in frame. Suppress high-risk alerts.
    private let recedingVelocityYThreshold: CGFloat = -0.02
    
    /// Minimum object area to consider (very small = 0.5% of frame)
    private let minimumTrackingArea: CGFloat = 0.003
    
    /// Area threshold for "close" objects — raised so only genuinely close vehicles trigger (8% of frame)
    private let closeAreaThreshold: CGFloat = 0.08
    
    /// Minimum area to emit "vehicle ahead" at all (avoid distant cars)
    private let vehicleAheadMinArea: CGFloat = 0.06
    
    /// Large object threshold (10% of frame)
    private let largeAreaThreshold: CGFloat = 0.10

    /// Consecutive frames object must be in center lane before we emit any vehicle alert
    private let requiredCenterLaneFrames: Int = 2

    /// Consecutive frame pairs with positive growth required for "closing fast"
    private let requiredClosingGrowthFrames: Int = 2

    /// Assumed system latency (inference + TTS + reaction) in seconds
    private let latencyCompensationSec: TimeInterval = 0.7

    /// Growth rate considered "fast approach" (area/sec)
    private let criticalGrowthThreshold: CGFloat = 0.04

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
            // Check for vehicle: only when in our lane (center strip); ignore adjacent/commuting traffic
            else if detection.label.isVehicle {
                guard isInCenterLane(detection.center) else {
                    updateTrack(with: detection, timestamp: timestamp, matchedIndex: matchedIndex)
                    continue
                }
                let adjacentLane = isConsistentlyAdjacentLane(track: matchedTrack)
                let sustainedInLane = consecutiveFramesInCenterLane(track: matchedTrack, currentCenter: detection.center) >= requiredCenterLaneFrames
                let consecutiveClosing = hasConsecutivePositiveGrowth(track: matchedTrack, currentArea: detection.area, currentTime: timestamp)
                if sustainedInLane, let event = checkVehicle(detection, growthRate: growthRate, velocity: velocity, adjacentLane: adjacentLane, consecutiveClosingGrowth: consecutiveClosing, timestamp: timestamp) {
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
    
    private func checkVehicle(_ detection: DetectedObject, growthRate: CGFloat, velocity: CGPoint?, adjacentLane: Bool, consecutiveClosingGrowth: Bool, timestamp: Date) -> RoadHazardEvent? {
        let alertKey = "veh_\(detection.label.rawValue)"
        
        if let lastTime = lastAlertTimes[alertKey], timestamp.timeIntervalSince(lastTime) < alertCooldown {
            return nil
        }
        
        // Receding = passing or moving away. Don't treat as closing or high-risk.
        let isRecedingByGrowth = growthRate < recedingGrowthThreshold
        let isRecedingByVelocity = (velocity?.y ?? 0) < recedingVelocityYThreshold
        if isRecedingByGrowth || isRecedingByVelocity {
            return nil
        }
        
        // Only alert when vehicle is actually close enough to matter (not every car in vicinity)
        guard detection.area >= vehicleAheadMinArea else { return nil }
        
        let isApproaching = growthRate > 0.005
        let rawClosingFast = growthRate > rapidGrowthThreshold
        // "Closing fast" only with sustained positive growth (2+ frames), and not adjacent-lane traffic
        let isClosingFast = rawClosingFast && consecutiveClosingGrowth && !adjacentLane
        let isLarge = detection.area > closeAreaThreshold
        
        guard isLarge || (isApproaching && detection.area > minimumTrackingArea * 3) else {
            return nil
        }
        
        var score = computeHazardScore(detection: detection, growthRate: growthRate, isVulnerableRoadUser: false)
        
        // Latency compensation only when approaching
        if isApproaching {
            let projArea = projectedArea(current: detection.area, growthRate: growthRate)
            let areaGrowthFactor = min(1.5, projArea / max(0.001, detection.area))
            score = min(1, score * Float(areaGrowthFactor) + 0.1)
        }
        
        var severity = scoreToSeverity(score, isClosingFast: isClosingFast)
        if adjacentLane {
            severity = min(severity, .low)
        }
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
        let entersCenterLane = isInCenterLane(predictedCenter)
        let gettingCloser = predictedArea > detection.area * 1.02 || displacement.y > 0.01

        // Only alert when object will enter *our* lane (center), not just the wide path
        guard entersCenterLane && gettingCloser else { return nil }
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
        let score = Float(min(1, predictedArea / CGFloat(largeAreaThreshold))) * 0.5 + (severity == .high ? 0.4 : 0.2)
        return RoadHazardEvent(
            type: .futurePath,
            severity: severity,
            timestamp: timestamp,
            description: desc,
            triggeringObject: detection,
            hazardScore: score
        )
    }
    
    // MARK: - Helpers
    
    private func isInForwardPath(_ detection: DetectedObject) -> Bool {
        isInForwardPath(detection.center)
    }

    private func isInForwardPath(_ center: CGPoint) -> Bool {
        return forwardPathXRange.contains(center.x) && forwardPathYRange.contains(center.y)
    }

    /// True if object is in the narrow center strip ("in our lane"). Used for high-risk / closing-fast only.
    private func isInCenterLane(_ center: CGPoint) -> Bool {
        return centerLaneXRange.contains(center.x) && forwardPathYRange.contains(center.y)
    }

    /// Mean lateral position (0–1) over the track's history. Nil if no track or no samples.
    private func meanLateralPosition(track: MotionTrack?) -> CGFloat? {
        guard let track = track, !track.samples.isEmpty else { return nil }
        let sum = track.samples.reduce(CGFloat(0)) { $0 + $1.center.x }
        return sum / CGFloat(track.samples.count)
    }

    /// True if the object has been consistently left or right of center (adjacent lane) over recent frames.
    private func isConsistentlyAdjacentLane(track: MotionTrack?) -> Bool {
        guard let meanX = meanLateralPosition(track: track) else { return false }
        return meanX < centerLaneXRange.lowerBound || meanX > centerLaneXRange.upperBound
    }

    /// Number of consecutive frames (including current) the object has been in the center lane. Used to require sustained presence before alerting.
    private func consecutiveFramesInCenterLane(track: MotionTrack?, currentCenter: CGPoint) -> Int {
        guard centerLaneXRange.contains(currentCenter.x) else { return 0 }
        var count = 1
        guard let track = track else { return count }
        for sample in track.samples.reversed() {
            guard centerLaneXRange.contains(sample.center.x) else { break }
            count += 1
        }
        return count
    }

    /// True if we have positive growth over the last N consecutive frame intervals (avoids one-frame "closing" spikes).
    private func hasConsecutivePositiveGrowth(track: MotionTrack?, currentArea: CGFloat, currentTime: Date) -> Bool {
        guard let track = track, track.samples.count >= 2, let last = track.lastSample else { return false }
        let prev = track.samples[track.samples.count - 2]
        let dt = CGFloat(currentTime.timeIntervalSince(last.timestamp))
        let prevDt = CGFloat(last.timestamp.timeIntervalSince(prev.timestamp))
        guard dt > 0, prevDt > 0 else { return false }
        let currentGrowth = (currentArea - last.area) / dt
        let prevGrowth = (last.area - prev.area) / prevDt
        return currentGrowth > 0.005 && prevGrowth > 0.005
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

        return 0  // No prior sample to compute growth
    }
}
