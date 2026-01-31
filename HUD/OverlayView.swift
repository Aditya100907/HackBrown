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
            }
        }
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
            
            // Label background
            Text(labelText)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(boxColor)
                .cornerRadius(2)
                .offset(y: -20)
        }
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
    
    /// Label text with confidence
    private var labelText: String {
        let confidence = Int(detection.confidence * 100)
        return "\(detection.label.rawValue) \(confidence)%"
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
        guard let state = attentionState else { return "No face" }
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
                Text("No detections")
                    .font(.caption)
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
    
    // Alert state
    let currentAlert: AlertType?
    let isAlertActive: Bool
    
    // Frame size
    let frameSize: CGSize
    
    var body: some View {
        ZStack {
            // Bounding boxes for detections
            if let detections = roadOutput?.detections {
                DetectionOverlayView(
                    detections: detections,
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
                    // Left: Driver status
                    DriverStatusView(
                        attentionState: driverOutput?.attentionState,
                        presageOutput: driverOutput?.presageOutput
                    )
                    
                    Spacer()
                    
                    // Right: Road status
                    RoadStatusView(output: roadOutput)
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
                hazardEvents: [],
                timestamp: Date()
            ),
            driverOutput: nil,
            currentAlert: .vehicleApproaching,
            isAlertActive: true,
            frameSize: CGSize(width: 390, height: 844)
        )
    }
}
