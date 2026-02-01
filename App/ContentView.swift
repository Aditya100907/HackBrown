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
                            currentAlert: viewModel.currentAlert,
                            isAlertActive: viewModel.isAlertActive,
                            frameSize: geometry.size
                        )
                    }
                }
                .ignoresSafeArea(edges: .top)
                
                // Control panel at bottom
                ControlPanel(viewModel: viewModel)
            }
        }
        .preferredColorScheme(.dark)
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
            // App mode selector
            HStack(spacing: 8) {
                ForEach(AppMode.allCases) { mode in
                    AppModeButton(
                        mode: mode,
                        isSelected: viewModel.appMode == mode
                    ) {
                        viewModel.setAppMode(mode)
                    }
                }
            }
            .padding(.horizontal)
            
            // Status bar
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
                
                // Start/Stop button
                Button(action: {
                    viewModel.toggleRunning()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                        Text(viewModel.isRunning ? "Stop" : "Start")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(viewModel.isRunning ? Color.red : Color.green)
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal)
            
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
            return "Running - \(viewModel.appMode.rawValue)"
        }
        return "Stopped"
    }
}

// MARK: - App Mode Button

struct AppModeButton: View {
    let mode: AppMode
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: iconName)
                    .font(.title3)
                Text(mode.rawValue)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.3) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.gray.opacity(0.5), lineWidth: 1)
            )
        }
        .foregroundColor(isSelected ? .white : .gray)
    }
    
    private var iconName: String {
        switch mode {
        case .road:
            return "car.fill"
        case .driver:
            return "person.fill"
        case .demo:
            return "film.fill"
        }
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
            if let image = viewModel.currentFrameImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                // Placeholder when no frame
                VStack(spacing: 16) {
                    Image(systemName: placeholderIcon)
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    
                    Text("Select a mode and tap Start")
                        .font(.headline)
                        .foregroundColor(.gray)
                    
                    Text(viewModel.appMode.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
    
    private var placeholderIcon: String {
        switch viewModel.appMode {
        case .road:
            return "car.fill"
        case .driver:
            return "person.fill"
        case .demo:
            return "film.fill"
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
