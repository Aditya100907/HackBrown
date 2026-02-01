//
//  OverlayView.swift
//  HackBrown
//
//  Minimal HUD overlay: bounding boxes / highlights showing what the model sees.
//  No complex UI - just visual feedback of detections.
//

import SwiftUI

// MARK: - Detection Overlay View

/// Overlay view that draws bounding boxes for detections
struct DetectionOverlayView: View {
    /// Detected objects to display
    let detections: [DetectedObject]

    /// Optional motion vectors per detection (normalized units per second)
    let motionVectors: [UUID: CGPoint]
    
    /// Frame size to scale coordinates
    let frameSize: CGSize
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(detections) { detection in
                    BoundingBoxView(
                        detection: detection,
                        containerSize: geometry.size
                    )
                }

                ForEach(detections) { detection in
                    if let vector = motionVectors[detection.id],
                       shouldDrawArrow(for: detection) {
                        let start = scaledCenter(for: detection, in: geometry.size)
                        let scaledVector = scale(vector: vector, container: geometry.size)
                        let end = CGPoint(
                            x: start.x + scaledVector.x,
                            y: start.y + scaledVector.y
                        )

                        ArrowShape(start: start, end: end)
                            .stroke(color(for: detection), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .shadow(color: color(for: detection).opacity(0.5), radius: 4)
                    }
                }
            }
        }
    }

    private func scaledCenter(for detection: DetectedObject, in size: CGSize) -> CGPoint {
        CGPoint(
            x: detection.center.x * size.width,
            y: detection.center.y * size.height
        )
    }

    private func scale(vector: CGPoint, container: CGSize) -> CGPoint {
        let scale = min(container.width, container.height) * 0.6
        let dx = vector.x * scale
        let dy = vector.y * scale

        // Clamp length
        let length = hypot(dx, dy)
        let maxLength = min(container.width, container.height) * 0.25
        if length < 6 { return .zero }
        let factor = min(1.0, maxLength / length)
        return CGPoint(x: dx * factor, y: dy * factor)
    }

    private func shouldDrawArrow(for detection: DetectedObject) -> Bool {
        detection.area > 0.02 && detection.center.y > 0.25
    }

    private func color(for detection: DetectedObject) -> Color {
        if detection.label.isVulnerableRoadUser { return .red }
        if detection.label.isVehicle { return .yellow }
        return .blue
    }
}

// MARK: - Bounding Box View

/// Individual bounding box for a detection
struct BoundingBoxView: View {
    let detection: DetectedObject
    let containerSize: CGSize
    
    var body: some View {
        let rect = scaledRect
        
        ZStack(alignment: .topLeading) {
            // Bounding box
            Rectangle()
                .stroke(boxColor, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
            
            // Thick border
            Rectangle()
                .stroke(boxColor, lineWidth: 3)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
    
    /// Scale normalized coordinates to container size
    private var scaledRect: CGRect {
        let box = detection.boundingBox
        return CGRect(
            x: box.origin.x * containerSize.width,
            y: box.origin.y * containerSize.height,
            width: box.width * containerSize.width,
            height: box.height * containerSize.height
        )
    }
    
    /// Color based on object type
    private var boxColor: Color {
        if detection.label.isVulnerableRoadUser {
            return .red  // Pedestrians/cyclists in red
        } else if detection.label.isVehicle {
            return .yellow  // Vehicles in yellow
        }
        return .blue
    }
    
    /// Label text (just object name, no confidence)
    private var labelText: String {
        return detection.label.rawValue.capitalized
    }
}

// MARK: - Arrow Shape

/// Simple arrow from start → end with a triangular head
struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        // Arrowhead
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 12
        let headAngle: CGFloat = .pi / 8

        let point1 = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let point2 = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        path.move(to: end)
        path.addLine(to: point1)
        path.move(to: end)
        path.addLine(to: point2)

        return path
    }
}

// MARK: - Alert Indicator View

/// Visual indicator when an alert is active
struct AlertIndicatorView: View {
    let alertType: AlertType?
    let isActive: Bool
    
    var body: some View {
        if isActive, let alert = alertType {
            HStack(spacing: 8) {
                // Pulsing indicator
                Circle()
                    .fill(alertColor(for: alert))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(alertColor(for: alert), lineWidth: 2)
                            .scaleEffect(1.5)
                            .opacity(0.5)
                    )
                
                Text(alert.phrase)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(alertColor(for: alert).opacity(0.8))
            .cornerRadius(20)
            .transition(.scale.combined(with: .opacity))
        }
    }
    
    private func alertColor(for alert: AlertType) -> Color {
        if alert.isRoadHazard {
            return .red
        } else if alert.isDistraction {
            return .orange
        } else if alert.isDrowsiness {
            return .purple
        }
        return .blue
    }
}

// MARK: - Driver Status View

/// Shows driver attention status
struct DriverStatusView: View {
    let attentionState: AttentionState?
    let presageOutput: PresageOutput?
    let heartRateBPM: Double?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Eyes status
            HStack(spacing: 4) {
                Image(systemName: eyeIcon)
                    .foregroundColor(eyeColor)
                Text(eyeStatus)
                    .font(.caption)
                    .foregroundColor(.white)
            }
            
            // Gaze direction
            if let gaze = attentionState?.gazeDirection, gaze != .unknown {
                HStack(spacing: 4) {
                    Image(systemName: gazeIcon(for: gaze))
                        .foregroundColor(gaze.isOnRoad ? .green : .orange)
                    Text(gazeText(for: gaze))
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            
            // Fatigue level (from Presage)
            if let presage = presageOutput, presage.isValid {
                HStack(spacing: 4) {
                    Image(systemName: "battery.100")
                        .foregroundColor(fatigueColor(presage.fatigueScore))
                    Text("Fatigue: \(Int(presage.fatigueScore * 100))%")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            
            // Heart rate (from SmartSpectra)
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundColor(heartRateBPM != nil ? .red : .gray)
                if let hr = heartRateBPM {
                    Text("Heart Rate: \(Int(hr)) BPM")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                } else {
                    Text("Heart Rate: Measuring...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
    
    private var eyeIcon: String {
        guard let state = attentionState else { return "eye.slash" }
        return state.eyesOpen ? "eye" : "eye.slash"
    }
    
    private var eyeColor: Color {
        guard let state = attentionState else { return .gray }
        return state.eyesOpen ? .green : .red
    }
    
    private var eyeStatus: String {
        guard let state = attentionState else { return "Driver Mode" }
        if !state.faceDetected { return "No face" }
        return state.eyesOpen ? "Eyes open" : "Eyes closed"
    }
    
    private func gazeIcon(for gaze: GazeDirection) -> String {
        switch gaze {
        case .forward: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .unknown: return "questionmark"
        }
    }
    
    private func gazeText(for gaze: GazeDirection) -> String {
        switch gaze {
        case .forward: return "Looking forward"
        case .down: return "Looking down"
        case .left: return "Looking left"
        case .right: return "Looking right"
        case .unknown: return "Unknown"
        }
    }
    
    private func fatigueColor(_ score: Float) -> Color {
        if score > 0.7 { return .red }
        if score > 0.5 { return .orange }
        if score > 0.3 { return .yellow }
        return .green
    }
}

// MARK: - Road Status View

/// Shows road detection summary
struct RoadStatusView: View {
    let output: RoadPipelineOutput?
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let output = output {
                // Show detection counts or scanning indicator
                let hasDetections = !output.vehicles.isEmpty || !output.vulnerableRoadUsers.isEmpty
                
                if hasDetections {
                    // Vehicle count
                    if !output.vehicles.isEmpty {
                        HStack(spacing: 4) {
                            Text("\(output.vehicles.count)")
                                .font(.caption)
                                .fontWeight(.bold)
                            Image(systemName: "car.fill")
                        }
                        .foregroundColor(.yellow)
                    }
                    
                    // Pedestrian/cyclist count
                    if !output.vulnerableRoadUsers.isEmpty {
                        HStack(spacing: 4) {
                            Text("\(output.vulnerableRoadUsers.count)")
                                .font(.caption)
                                .fontWeight(.bold)
                            Image(systemName: "figure.walk")
                        }
                        .foregroundColor(.red)
                    }
                } else {
                    // Model is running but no relevant objects detected
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                        Text("Scanning...")
                            .font(.caption)
                    }
                    .foregroundColor(.green)
                }
                
                // Hazard warning
                if output.hasCriticalHazard {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("HAZARD")
                            .font(.caption)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.red)
                }
            } else {
                // Pipeline not running or no output yet
                HStack(spacing: 4) {
                    Image(systemName: "video.slash")
                    Text("Waiting...")
                        .font(.caption)
                }
                .foregroundColor(.gray)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
}

// MARK: - Full HUD Overlay

/// Complete HUD overlay combining all elements
struct HUDOverlay: View {
    // Road pipeline state
    let roadOutput: RoadPipelineOutput?
    
    // Driver pipeline state
    let driverOutput: DriverPipelineOutput?
    
    // Heart rate (from SmartSpectra via viewModel - takes priority)
    let heartRateBPM: Double?
    
    // Attention state (from Vision analysis on SmartSpectra frames)
    let attentionState: AttentionState?
    
    // Alert state
    let currentAlert: AlertType?
    let isAlertActive: Bool
    
    // Frame size
    let frameSize: CGSize
    
    // Whether front camera is primary (driver pipeline active)
    let frontIsPrimary: Bool
    
    var body: some View {
        ZStack {
            // Bounding boxes for detections (ONLY when back camera is active)
            if !frontIsPrimary, let detections = roadOutput?.detections {
                DetectionOverlayView(
                    detections: detections,
                    motionVectors: roadOutput?.motionVectors ?? [:],
                    frameSize: frameSize
                )
            }
            
            // Status overlays
            VStack {
                // Top: Alert indicator (centered)
                HStack {
                    Spacer()
                    AlertIndicatorView(
                        alertType: currentAlert,
                        isActive: isAlertActive
                    )
                    Spacer()
                }
                .padding(.top, 60)
                
                Spacer()
                
                // Bottom: Status panels
                HStack(alignment: .bottom) {
                    // Left: Driver status - ONLY show when front camera is primary
                    if frontIsPrimary {
                        DriverStatusView(
                            attentionState: attentionState ?? driverOutput?.attentionState,
                            presageOutput: driverOutput?.presageOutput,
                            heartRateBPM: heartRateBPM ?? driverOutput?.heartRateBPM
                        )
                    }
                    
                    Spacer()
                    
                    // Right: Road status - ONLY show when back camera is primary
                    if !frontIsPrimary {
                        RoadStatusView(output: roadOutput)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)  // Above control panel
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black
        
        HUDOverlay(
            roadOutput: RoadPipelineOutput(
                detections: [
                    DetectedObject(
                        label: .car,
                        confidence: 0.92,
                        boundingBox: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.3)
                    ),
                    DetectedObject(
                        label: .person,
                        confidence: 0.85,
                        boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.15, height: 0.35)
                    )
                ],
                motionVectors: [:],
                hazardEvents: [],
                timestamp: Date()
            ),
            driverOutput: nil,
            heartRateBPM: 72,
            attentionState: nil,
            currentAlert: .obstacleAhead,
            isAlertActive: true,
            frameSize: CGSize(width: 390, height: 844),
            frontIsPrimary: false
        )
    }
}
