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
    case repeatedDrowsyBlinks = "repeated_drowsy_blinks"  // 3+ long blinks in a row
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
    
    // MARK: - Configuration (tuned for real-world use - less sensitive, less annoying)
    
    /// Minimum eye aspect ratio to consider eyes open (lower = more forgiving)
    private let eyeOpenThreshold: CGFloat = 0.12
    
    /// How long eyes must be CONTINUOUSLY closed to trigger drowsiness alert (very long to avoid false positives)
    private let drowsinessThreshold: TimeInterval = 2.5
    
    /// Threshold for a "long blink" indicating drowsiness (0.5s = obviously slow blink)
    private let longBlinkThreshold: TimeInterval = 0.5
    
    /// Number of consecutive long blinks to trigger drowsiness warning (need 5 slow blinks)
    private let consecutiveLongBlinksForAlert: Int = 5
    
    /// Time window to count consecutive long blinks (reset if no blink within this time)
    private let blinkWindowTimeout: TimeInterval = 30.0
    
    /// How long looking down to trigger distraction alert (3.5s = clearly not glancing)
    private let lookingDownThreshold: TimeInterval = 3.5
    
    /// How long looking left/right/away to trigger distraction alert (4s = definitely not just checking mirrors)
    private let lookingAwayThreshold: TimeInterval = 4.0
    
    /// Pitch angle threshold for "looking down" (radians) - more forgiving
    private let lookingDownPitchThreshold: Float = -0.35
    
    /// Yaw angle threshold for "looking sideways" (radians) - wider tolerance for mirror checks
    private let lookingSidewaysYawThreshold: Float = 0.5
    
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
    
    // MARK: - Alert Cooldowns (prevent spam)
    
    /// Minimum time between drowsiness alerts (30 seconds)
    private let drowsinessAlertCooldown: TimeInterval = 30.0
    
    /// Minimum time between gaze alerts (20 seconds)
    private let gazeAlertCooldown: TimeInterval = 20.0
    
    /// Last time a drowsiness alert was triggered
    private var lastDrowsinessAlert: Date?
    
    /// Last time a gaze alert was triggered
    private var lastGazeAlert: Date?
    
    /// Minimum face confidence to trust detection (0.5 = moderate confidence)
    private let minFaceConfidence: Float = 0.5
    
    // MARK: - Long Blink Detection (Drowsiness Pattern)
    
    /// Count of consecutive long blinks (eyes closed > 0.5s)
    private var consecutiveLongBlinks: Int = 0
    
    /// Timestamp of the last recorded long blink
    private var lastLongBlinkTime: Date?
    
    /// Whether we're currently in a blink (eyes closed)
    private var isCurrentlyBlinking: Bool = false
    
    /// When the current blink started
    private var currentBlinkStartTime: Date?
    
    /// Whether we already triggered drowsiness alert for current blink sequence
    private var drowsyBlinkAlertTriggered: Bool = false
    
    // MARK: - Analysis
    
    /// Analyze a frame for driver attention (synchronous, optimized)
    /// - Parameter pixelBuffer: Front camera frame
    /// - Returns: Current attention state
    func analyzeAttention(in pixelBuffer: CVPixelBuffer) -> AttentionState {
        let timestamp = Date()
        var faceDetected = false
        var eyesOpen = true
        var gazeDirection: GazeDirection = .unknown
        var faceConfidence: Float = 0
        
        // Use synchronous VNSequenceRequestHandler for efficiency (no semaphore needed)
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3  // Faster revision
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
            
            if let face = request.results?.first {
                faceDetected = true
                faceConfidence = face.confidence
                
                if let landmarks = face.landmarks {
                    eyesOpen = analyzeEyeState(landmarks: landmarks)
                }
                gazeDirection = analyzeGazeDirection(face: face)
            }
        } catch {
            // Silent fail - face detection errors are common and expected
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
        
        // Skip unreliable detections (low confidence or no face)
        let reliableDetection = state.faceDetected && state.faceConfidence >= minFaceConfidence
        
        // ============================================================
        // LONG BLINK DETECTION (Drowsiness Pattern)
        // Track blinks that last > 0.5s - 5 in a row = drowsiness warning
        // ============================================================
        
        if !state.eyesOpen && reliableDetection {
            // Eyes just closed - start tracking this blink
            if !isCurrentlyBlinking {
                isCurrentlyBlinking = true
                currentBlinkStartTime = now
            }
        } else if state.eyesOpen && isCurrentlyBlinking {
            // Eyes just opened - blink ended, check duration
            isCurrentlyBlinking = false
            
            if let blinkStart = currentBlinkStartTime {
                let blinkDuration = now.timeIntervalSince(blinkStart)
                
                // Check if this was a "long blink" (> 0.5 seconds)
                if blinkDuration >= longBlinkThreshold {
                    // Check if we should reset the counter (too much time passed)
                    if let lastBlink = lastLongBlinkTime,
                       now.timeIntervalSince(lastBlink) > blinkWindowTimeout {
                        consecutiveLongBlinks = 0
                        drowsyBlinkAlertTriggered = false
                    }
                    
                    // Record this long blink
                    consecutiveLongBlinks += 1
                    lastLongBlinkTime = now
                    
                    // Check if we've hit threshold AND cooldown has passed
                    let cooldownOK = lastDrowsinessAlert == nil || now.timeIntervalSince(lastDrowsinessAlert!) >= drowsinessAlertCooldown
                    
                    if consecutiveLongBlinks >= consecutiveLongBlinksForAlert && !drowsyBlinkAlertTriggered && cooldownOK {
                        events.append(AttentionEvent(
                            type: .repeatedDrowsyBlinks,
                            severity: .high,
                            timestamp: now,
                            description: "Drowsy - \(consecutiveLongBlinks) slow blinks",
                            duration: nil
                        ))
                        drowsyBlinkAlertTriggered = true
                        lastDrowsinessAlert = now
                    }
                } else {
                    // Normal quick blink - DON'T reset the counter (allow mixed blinks)
                    // Only reset if it's been too long since last long blink
                }
            }
            currentBlinkStartTime = nil
        }
        
        // ============================================================
        // PROLONGED EYE CLOSURE (Existing drowsiness detection)
        // Only trigger with reliable detection and respecting cooldown
        // ============================================================
        
        // Check for drowsiness (prolonged eye closure) - only with reliable detection
        if !state.eyesOpen && reliableDetection {
            if eyesClosedSince == nil {
                eyesClosedSince = now
            } else if let closedSince = eyesClosedSince {
                let duration = now.timeIntervalSince(closedSince)
                let cooldownOK = lastDrowsinessAlert == nil || now.timeIntervalSince(lastDrowsinessAlert!) >= drowsinessAlertCooldown
                
                if duration >= drowsinessThreshold && cooldownOK {
                    let severity: AttentionSeverity = duration > drowsinessThreshold * 2 ? .critical : .high
                    events.append(AttentionEvent(
                        type: .drowsiness,
                        severity: severity,
                        timestamp: now,
                        description: "Eyes closed for \(String(format: "%.1f", duration))s",
                        duration: duration
                    ))
                    lastDrowsinessAlert = now
                    eyesClosedSince = nil  // Reset to prevent spam
                }
            }
        } else {
            eyesClosedSince = nil
        }
        
        // ============================================================
        // GAZE DIRECTION ALERTS (with cooldown to prevent spam)
        // ============================================================
        
        // Reset trackers for directions we're not currently looking
        if state.gazeDirection != .down { gazeDownSince = nil }
        if state.gazeDirection != .left { gazeLeftSince = nil }
        if state.gazeDirection != .right { gazeRightSince = nil }
        if state.gazeDirection != .unknown || !reliableDetection { gazeUnknownSince = nil }
        
        // Only check gaze with reliable detection and cooldown
        let gazeCooldownOK = lastGazeAlert == nil || now.timeIntervalSince(lastGazeAlert!) >= gazeAlertCooldown
        
        // Check for looking down (3.5s threshold)
        if state.gazeDirection == .down && reliableDetection && gazeCooldownOK {
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
                    lastGazeAlert = now
                    gazeDownSince = nil  // Reset to prevent spam
                }
            }
        }
        
        // Check for looking left (4.0s threshold)
        if state.gazeDirection == .left && reliableDetection && gazeCooldownOK {
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
                    lastGazeAlert = now
                    gazeLeftSince = nil  // Reset to prevent spam
                }
            }
        }
        
        // Check for looking right (4.0s threshold)
        if state.gazeDirection == .right && reliableDetection && gazeCooldownOK {
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
                    lastGazeAlert = now
                    gazeRightSince = nil  // Reset to prevent spam
                }
            }
        }
        
        // NOTE: Unknown gaze direction and no-face events are NOT generated
        // to avoid annoying false positives. The system only alerts on
        // clear, reliable detections of actual drowsiness or distraction.
        
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
        
        // Reset blink tracking
        consecutiveLongBlinks = 0
        lastLongBlinkTime = nil
        isCurrentlyBlinking = false
        currentBlinkStartTime = nil
        drowsyBlinkAlertTriggered = false
        
        // Reset cooldowns (allow immediate alerts after reset)
        lastDrowsinessAlert = nil
        lastGazeAlert = nil
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
