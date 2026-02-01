//
//  ContentView.swift
//  HackBrown
//
//  Root view: mode selector, frame preview with HUD overlay, and controls.
//  Full driving assistant UI with road and driver monitoring.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Frame preview with HUD overlay (main area)
                GeometryReader { geometry in
                    ZStack {
                        // Camera/video frame
                        FramePreviewView(viewModel: viewModel)
                        
                        // HUD overlay
                        HUDOverlay(
                            roadOutput: viewModel.roadOutput,
                            driverOutput: viewModel.driverOutput,
                            heartRateBPM: viewModel.heartRateBPM,
                            attentionState: viewModel.attentionState,
                            currentAlert: viewModel.currentAlert,
                            isAlertActive: viewModel.isAlertActive,
                            frameSize: geometry.size,
                            frontIsPrimary: viewModel.frontIsPrimary
                        )
                    }
                }
                .ignoresSafeArea(edges: .top)
                
                // Control panel at bottom
                ControlPanel(viewModel: viewModel)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.showingVideoPicker) {
            VideoPickerView(
                viewModel: viewModel,
                videos: VideoManager.scanBundleForVideos()
            )
        }
        .onAppear {
            // Pre-cache TTS audio on launch
            viewModel.preCacheAudio()
        }
    }
}

// MARK: - Control Panel

struct ControlPanel: View {
    @ObservedObject var viewModel: ContentViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            // Status bar with buttons
            HStack {
                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // FPS display
                if viewModel.isRunning {
                    Text("\(viewModel.fps, specifier: "%.1f") FPS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                
                Spacer()
                
                // Start and Demo buttons
                HStack(spacing: 12) {
                    Button(action: { viewModel.toggleRunning() }) {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                            Text(viewModel.isRunning ? "Stop" : "Start")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(viewModel.isRunning ? Color.red : Color.green)
                        .cornerRadius(8)
                    }
                    
                    Button(action: { viewModel.startDemo() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "film.fill")
                            Text("Demo")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(viewModel.isRunning ? Color.gray : Color.blue)
                        .cornerRadius(8)
                    }
                    .disabled(viewModel.isRunning)
                }
            }
            .padding(.horizontal)
            
            // Demo only: Prev | video name | Next (contiguous loop)
            if viewModel.isRunning, viewModel.appMode == .demo, !viewModel.demoVideos.isEmpty {
                HStack(spacing: 16) {
                    Button("Prev") { viewModel.cycleToPreviousDemoVideo() }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.gray)
                        .cornerRadius(8)
                    
                    Text(currentDemoVideoLabel)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Button("Next") { viewModel.cycleToNextDemoVideo() }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.gray)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
            }
            
            // Alert history (last few alerts)
            if !viewModel.alertManager.recentAlerts.isEmpty {
                AlertHistoryBar(alerts: viewModel.alertManager.recentAlerts)
            }
        }
        .padding(.vertical, 12)
        .background(Color(white: 0.1))
    }
    
    private var statusColor: Color {
        if viewModel.isRunning {
            if viewModel.isAlertActive {
                return .orange
            }
            return .green
        }
        return .red
    }
    
    private var statusText: String {
        if viewModel.isRunning {
            if viewModel.isAlertActive {
                return "Alert Active"
            }
            // Show mode based on which camera is primary
            if viewModel.isDualCameraActive {
                return viewModel.frontIsPrimary ? "Driver Mode" : "Road Mode"
            }
            return "Running - Demo"
        }
        return "Stopped"
    }
    
    private var currentDemoVideoLabel: String {
        guard viewModel.currentDemoVideoIndex < viewModel.demoVideos.count else { return "" }
        let video = viewModel.demoVideos[viewModel.currentDemoVideoIndex]
        return "\(video.displayName) (\(viewModel.currentDemoVideoIndex + 1)/\(viewModel.demoVideos.count))"
    }
}

// MARK: - Alert History Bar

struct AlertHistoryBar: View {
    let alerts: [AlertHistoryEntry]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(alerts.prefix(5)) { entry in
                    AlertHistoryItem(entry: entry)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 28)
    }
}

struct AlertHistoryItem: View {
    let entry: AlertHistoryEntry
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(alertColor)
                .frame(width: 6, height: 6)
            
            Text(entry.type.rawValue.replacingOccurrences(of: "_", with: " "))
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Text(entry.timeAgo)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: 0.2))
        .cornerRadius(4)
    }
    
    private var alertColor: Color {
        if entry.type.isRoadHazard {
            return .red
        } else if entry.type.isDistraction {
            return .orange
        } else if entry.type.isDrowsiness {
            return .purple
        }
        return .blue
    }
}

// MARK: - Frame Preview View

struct FramePreviewView: View {
    @ObservedObject var viewModel: ContentViewModel
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // Main fullscreen camera view
                if let image = viewModel.currentFrameImage {
                    // SmartSpectra outputs portrait frames - need rotation for landscape display
                    // Dual camera outputs landscape frames - no rotation needed
                    if viewModel.isSmartSpectraActive {
                        // SmartSpectra camera (driver mode) - rotate 270° like original code
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .rotationEffect(.degrees(270))
                            .scaleEffect(0.5)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        // Dual camera / road mode - already landscape, no rotation
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                } else {
                    // Placeholder when no frame
                    VStack(spacing: 16) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("Tap Start to begin")
                            .font(.headline)
                            .foregroundColor(.gray)
                        
                        Text("Dual camera with road detection")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                
                // BeReal-style PiP view (secondary camera in corner)
                // Only shown when dual camera is active
                if viewModel.isDualCameraActive {
                    PiPCameraView(
                        image: viewModel.secondaryFrameImage,
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewModel.togglePrimaryCamera()
                            }
                        }
                    )
                    .padding(.top, 60)  // Below status bar / notch
                    .padding(.trailing, 16)
                }
            }
        }
    }
}

// MARK: - PiP Camera View (BeReal-style)

/// Picture-in-Picture camera view for secondary camera feed
/// Tapping swaps primary and secondary cameras
struct PiPCameraView: View {
    let image: UIImage?
    let onTap: () -> Void
    
    // PiP dimensions
    private let pipWidth: CGFloat = 120
    private let pipHeight: CGFloat = 160
    private let cornerRadius: CGFloat = 16
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: pipWidth, height: pipHeight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                // Placeholder while waiting for frames
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(white: 0.2))
                    .frame(width: pipWidth, height: pipHeight)
                    .overlay(
                        ProgressView()
                            .tint(.white)
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white, lineWidth: 3)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
