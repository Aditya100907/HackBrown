# HackBrown

Driving assistant prototype with road hazard detection and driver monitoring.

## How to run

### Option 1: Xcode (recommended)

1. **Open the project**
   ```bash
   open HackBrown/HackBrown.xcodeproj
   ```

2. **Select a run destination**  
   In Xcode’s toolbar, choose an **iPhone Simulator** (e.g. iPhone 16) or a connected **iOS device**.

3. **Build and run**  
   Press **⌘R** or click the **Run** button.

### Option 2: Command line

From the repo root (`hack@brown/`):

1. **Build for simulator** (replace with a simulator name from `xcrun simctl list devices` if needed):
   ```bash
   cd HackBrown
   xcodebuild -project HackBrown.xcodeproj -scheme HackBrown \
     -destination 'platform=iOS Simulator,name=iPhone 16' \
     -configuration Debug build
   ```

2. **Run on simulator** (after building):
   ```bash
   xcrun simctl boot "iPhone 16" 2>/dev/null || true
   xcrun simctl install booted build/Debug-iphonesimulator/HackBrown.app
   xcrun simctl launch booted com.hackbrown.HackBrown
   ```

Or from the **HackBrown** directory:

- `open HackBrown.xcodeproj` — open in Xcode  
- Then use **⌘R** in Xcode to run.

## Requirements

- **macOS** with **Xcode** (iOS 15+)
- **iOS Simulator** or a physical **iPhone/iPad** for running the app

## Project layout

- **Alerts/** — TTS and alert handling  
- **App/** — SwiftUI views and view model  
- **Camera/** — Live camera and video file input  
- **Driver/** — Driver attention / Presage integration  
- **HUD/** — Overlay UI  
- **Road/** — Object detection and road heuristics  
