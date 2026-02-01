//
//  VideoPickerView.swift
//  HackBrown
//
//  SwiftUI view for selecting demo videos at runtime.
//  Displays list of available videos with metadata and allows user selection.
//

import SwiftUI

// MARK: - Video Picker View

/// Modal sheet for selecting demo videos
struct VideoPickerView: View {
    @ObservedObject var viewModel: ContentViewModel
    @Environment(\.dismiss) private var dismiss
    
    let videos: [DemoVideo]
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if videos.isEmpty {
                    emptyStateView
                } else {
                    videoListView
                }
            }
            .navigationTitle("Select Demo Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Video List
    
    private var videoListView: some View {
        List(videos) { video in
            Button(action: {
                selectVideo(video)
            }) {
                VideoRowView(video: video)
            }
            .listRowBackground(Color(white: 0.1))
        }
        .listStyle(.plain)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Demo Videos Found")
                .font(.title2)
                .foregroundColor(.white)
            
            Text("Add .mov, .mp4, or .m4v files to the Resources folder in Xcode")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Text("Make sure they're included in the HackBrown target's Copy Bundle Resources")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)
        }
    }
    
    // MARK: - Actions
    
    private func selectVideo(_ video: DemoVideo) {
        viewModel.startDemoWithVideo(video.name, ext: video.fileExtension)
        dismiss()
    }
}

// MARK: - Video Row View

/// Individual row in the video list
struct VideoRowView: View {
    let video: DemoVideo
    
    var body: some View {
        HStack(spacing: 12) {
            // Video icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                Image(systemName: "film.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
            }
            
            // Video info
            VStack(alignment: .leading, spacing: 4) {
                Text(video.displayName)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(video.fileName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // File size if available
                if let sizeMB = video.fileSizeMB {
                    Text(String(format: "%.1f MB", sizeMB))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Chevron
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Preview

#Preview {
    VideoPickerView(
        viewModel: ContentViewModel(),
        videos: [
            DemoVideo(
                id: "testVid1.mov",
                name: "testVid1",
                fileName: "testVid1.mov",
                fileExtension: "mov",
                url: nil
            ),
            DemoVideo(
                id: "highway_driving.mp4",
                name: "highway_driving",
                fileName: "highway_driving.mp4",
                fileExtension: "mp4",
                url: nil
            )
        ]
    )
}
