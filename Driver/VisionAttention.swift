//
//  VisionAttention.swift
//  HackBrown
//
//  Vision framework face landmark analysis for driver attention monitoring.
//  Detects: eyes off road / looking down, prolonged eye closure (drowsiness).
//

import Foundation
import Vision
import CoreVideo

// MARK: - Attention State

/// Current attention state of the driver
struct AttentionState {
    /// Whether eyes are detected as open
    let eyesOpen: Bool
    
    /// Estimated gaze direction (simplified)
    let gazeDirection: GazeDirection
    
    /// Face detection confidence
    let faceConfidence: Float
    
    /// Whether a face was detected at all
    let faceDetected: Bool
    
    /// Timestamp of this observation
    let timestamp: Date
}

/// Simplified gaze direction categories
enum GazeDirection {
    case forward      // Looking at road
    case down         // Looking down (phone?)
    case left         // Looking left
    case right        // Looking right
    case unknown      // Cannot determine
    
    var isOnRoad: Bool {
        self == .forward
    }
}

// MARK: - Driver Attention Events

/// Types of driver attention issues
enum AttentionIssueType: String {
    case eyesOffRoad = "eyes_off_road"
    case drowsiness = "drowsiness"
    case noFaceDetected = "no_face"
}

/// A driver attention event
struct AttentionEvent {
    let type: AttentionIssueType
    let severity: AttentionSeverity
    let timestamp: Date
    let description: String
    
    /// Duration of the issue (for escalation)
    let duration: TimeInterval?
}

/// Severity of attention issues
enum AttentionSeverity: Int, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4
    
    static func < (lhs: AttentionSeverity, rhs: AttentionSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Vision Attention Analyzer

/// Analyzes driver attention using Vision face landmarks
final class VisionAttention {
    
    // MARK: - Configuration
    
    /// Minimum eye aspect ratio to consider eyes open
    private let eyeOpenThreshold: CGFloat = 0.15
    
    /// How long eyes must be closed to trigger drowsiness alert
    private let drowsinessThreshold: TimeInterval = 0.5
    
    /// How long looking down to trigger distraction alert (increased from 0.5s to 1.5s for less sensitivity)
    private let lookingDownThreshold: TimeInterval = 1.5
    
    /// How long looking left/right/away to trigger distraction alert (increased from 1.0s to 2.5s for less sensitivity)
    private let lookingAwayThreshold: TimeInterval = 2.5
    
    /// Pitch angle threshold for "looking down" (radians)
    private let lookingDownPitchThreshold: Float = -0.3
    
    /// Yaw angle threshold for "looking sideways" (radians)
    private let lookingSidewaysYawThreshold: Float = 0.4
    
    // MARK: - State Tracking
    
    /// When eyes were last detected as closed
    private var eyesClosedSince: Date?
    
    /// When gaze was last detected as looking down
    private var gazeDownSince: Date?
    
    /// When gaze was last detected as looking left
    private var gazeLeftSince: Date?
    
    /// When gaze was last detected as looking right
    private var gazeRightSince: Date?
    
    /// When gaze was last detected as unknown (face not properly detected)
    private var gazeUnknownSince: Date?
    
    /// Last detected state
    private var lastState: AttentionState?
    
    // MARK: - Analysis
    
    /// Analyze a frame for driver attention
    /// - Parameter pixelBuffer: Front camera frame
    /// - Returns: Current attention state
    func analyzeAttention(in pixelBuffer: CVPixelBuffer) -> AttentionState {
        let timestamp = Date()
        var faceDetected = false
        var eyesOpen = true
        var gazeDirection: GazeDirection = .unknown
        var faceConfidence: Float = 0
        
        let semaphore = DispatchSemaphore(value: 0)
        
        // Create face landmarks request
        let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
            defer { semaphore.signal() }
            
            guard let self = self,
                  let observations = request.results as? [VNFaceObservation],
                  let face = observations.first else {
                return
            }
            
            faceDetected = true
            faceConfidence = face.confidence
            
            // Analyze eye state
            if let landmarks = face.landmarks {
                eyesOpen = self.analyzeEyeState(landmarks: landmarks)
            }
            
            // Analyze gaze direction from face orientation
            gazeDirection = self.analyzeGazeDirection(face: face)
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
            semaphore.wait()
        } catch {
            print("[VisionAttention] Error: \(error)")
        }
        
        let state = AttentionState(
            eyesOpen: eyesOpen,
            gazeDirection: gazeDirection,
            faceConfidence: faceConfidence,
            faceDetected: faceDetected,
            timestamp: timestamp
        )
        
        lastState = state
        return state
    }
    
    /// Check for attention events based on current state
    /// - Parameter state: Current attention state
    /// - Returns: Array of attention events (may be empty)
    func checkForEvents(state: AttentionState) -> [AttentionEvent] {
        var events: [AttentionEvent] = []
        let now = state.timestamp
        
        // Check for drowsiness (prolonged eye closure)
        if !state.eyesOpen {
            if eyesClosedSince == nil {
                eyesClosedSince = now
            } else if let closedSince = eyesClosedSince {
                let duration = now.timeIntervalSince(closedSince)
                if duration >= drowsinessThreshold {
                    let severity: AttentionSeverity = duration > drowsinessThreshold * 2 ? .critical : .high
                    events.append(AttentionEvent(
                        type: .drowsiness,
                        severity: severity,
                        timestamp: now,
                        description: "Driver eyes closed for \(String(format: "%.1f", duration))s",
                        duration: duration
                    ))
                }
            }
        } else {
            eyesClosedSince = nil
        }
        
        // Check for gaze-specific distraction with different thresholds
        // Reset trackers for directions we're not currently looking
        if state.gazeDirection != .down { gazeDownSince = nil }
        if state.gazeDirection != .left { gazeLeftSince = nil }
        if state.gazeDirection != .right { gazeRightSince = nil }
        if state.gazeDirection != .unknown || !state.faceDetected { gazeUnknownSince = nil }
        
        // Check for looking down (shorter threshold - 0.5s)
        if state.gazeDirection == .down && state.faceDetected {
            if gazeDownSince == nil {
                gazeDownSince = now
            } else if let downSince = gazeDownSince {
                let duration = now.timeIntervalSince(downSince)
                if duration >= lookingDownThreshold {
                    let severity: AttentionSeverity = duration > lookingDownThreshold * 2 ? .high : .medium
                    events.append(AttentionEvent(
                        type: .eyesOffRoad,
                        severity: severity,
                        timestamp: now,
                        description: "Looking down for \(String(format: "%.1f", duration))s",
                        duration: duration
                    ))
                }
            }
        }
        
        // Check for looking left (1.0s threshold)
        if state.gazeDirection == .left && state.faceDetected {
            if gazeLeftSince == nil {
                gazeLeftSince = now
            } else if let leftSince = gazeLeftSince {
                let duration = now.timeIntervalSince(leftSince)
                if duration >= lookingAwayThreshold {
                    let severity: AttentionSeverity = duration > lookingAwayThreshold * 2 ? .high : .medium
                    events.append(AttentionEvent(
                        type: .eyesOffRoad,
                        severity: severity,
                        timestamp: now,
                        description: "Looking left for \(String(format: "%.1f", duration))s",
                        duration: duration
                    ))
                }
            }
        }
        
        // Check for looking right (1.0s threshold)
        if state.gazeDirection == .right && state.faceDetected {
            if gazeRightSince == nil {
                gazeRightSince = now
            } else if let rightSince = gazeRightSince {
                let duration = now.timeIntervalSince(rightSince)
                if duration >= lookingAwayThreshold {
                    let severity: AttentionSeverity = duration > lookingAwayThreshold * 2 ? .high : .medium
                    events.append(AttentionEvent(
                        type: .eyesOffRoad,
                        severity: severity,
                        timestamp: now,
                        description: "Looking right for \(String(format: "%.1f", duration))s",
                        duration: duration
                    ))
                }
            }
        }
        
        // Check for unknown gaze direction (1.0s threshold)
        if state.gazeDirection == .unknown && state.faceDetected {
            if gazeUnknownSince == nil {
                gazeUnknownSince = now
            } else if let unknownSince = gazeUnknownSince {
                let duration = now.timeIntervalSince(unknownSince)
                if duration >= lookingAwayThreshold {
                    let severity: AttentionSeverity = duration > lookingAwayThreshold * 2 ? .high : .medium
                    events.append(AttentionEvent(
                        type: .eyesOffRoad,
                        severity: severity,
                        timestamp: now,
                        description: "Looking away for \(String(format: "%.1f", duration))s",
                        duration: duration
                    ))
                }
            }
        }
        
        // Check for no face detected (driver not visible)
        if !state.faceDetected {
            events.append(AttentionEvent(
                type: .noFaceDetected,
                severity: .low,
                timestamp: now,
                description: "Driver face not detected",
                duration: nil
            ))
        }
        
        return events
    }
    
    /// Reset tracking state
    func reset() {
        eyesClosedSince = nil
        gazeDownSince = nil
        gazeLeftSince = nil
        gazeRightSince = nil
        gazeUnknownSince = nil
        lastState = nil
    }
    
    // MARK: - Private Analysis Methods
    
    /// Analyze eye openness from landmarks
    private func analyzeEyeState(landmarks: VNFaceLandmarks2D) -> Bool {
        // Get eye landmarks
        guard let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye else {
            return true  // Assume open if we can't detect
        }
        
        // Calculate eye aspect ratio (simplified)
        let leftEAR = calculateEyeAspectRatio(eye: leftEye)
        let rightEAR = calculateEyeAspectRatio(eye: rightEye)
        let avgEAR = (leftEAR + rightEAR) / 2
        
        return avgEAR > eyeOpenThreshold
    }
    
    /// Calculate eye aspect ratio from landmark points
    private func calculateEyeAspectRatio(eye: VNFaceLandmarkRegion2D) -> CGFloat {
        let points = eye.normalizedPoints
        guard points.count >= 6 else { return 1.0 }
        
        // Simplified EAR calculation
        // Vertical distances
        let v1 = distance(points[1], points[5])
        let v2 = distance(points[2], points[4])
        
        // Horizontal distance
        let h = distance(points[0], points[3])
        
        guard h > 0 else { return 1.0 }
        
        return (v1 + v2) / (2.0 * h)
    }
    
    /// Calculate distance between two points
    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }
    
    /// Analyze gaze direction from face orientation
    private func analyzeGazeDirection(face: VNFaceObservation) -> GazeDirection {
        // Use face roll, pitch, yaw if available
        guard let pitch = face.pitch?.floatValue,
              let yaw = face.yaw?.floatValue else {
            return .unknown
        }
        
        // Check if looking down
        if pitch < lookingDownPitchThreshold {
            return .down
        }
        
        // Check if looking sideways
        if abs(yaw) > lookingSidewaysYawThreshold {
            return yaw > 0 ? .left : .right
        }
        
        return .forward
    }
}
