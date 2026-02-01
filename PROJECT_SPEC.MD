# SafeRide — Smartphone-Based Driving Safety Assistant
### 24-Hour Hackathon Prototype (Single-App, Mode-Based Demo)

---

## 0. Project Intent (Read This First)

SafeRide is a **hackathon-scale prototype**, not a production system.

The goal is to demonstrate — clearly, reliably, and interactively — that a **single smartphone** can provide meaningful “new car” safety assistance (driver monitoring + road hazard alerts) to **very old cars with no ADAS hardware**.

**Primary success metric:**  
A judge can interact with the app for 1–2 minutes and immediately understand:
- what the system sees,
- what risks it detects,
- and why it issues alerts.

Reliability, latency, and demo clarity matter more than completeness or sophistication.

---

## 1. Demo Model (Critical)

### One App, Two Modes (Demonstrated Sequentially)

The app supports **two mutually exclusive modes**, selected via a UI toggle:

1. **Driver Mode** (Front Camera)
2. **Road Mode** (Rear Camera)

The demo intentionally runs these **one at a time** (not simultaneously) to ensure stability and clarity during judging.

This is a **deliberate design choice**, not a limitation of the concept.

Both modes:
- use live camera input,
- run real-time on-device CV,
- trigger real alerts.

---

## 2. High-Level System Overview

SafeRide consists of five conceptual subsystems:

1. **Camera Input Layer**
2. **Perception / Analysis Layer**
3. **Event Generation**
4. **Alert Orchestration**
5. **Voice Output + Minimal UI**

Each subsystem must remain **loosely coupled** to keep the project feasible within 24 hours.

---

## 3. Platform & Stack (Fixed, Non-Negotiable)

- Platform: iOS
- Language: Swift
- UI: SwiftUI
- Camera: AVFoundation
- Driver CV: Apple Vision (face landmarks)
- Road CV: CoreML with a pre-trained YOLO-style object detection model
- Driver State Signal: Presage SDK
- Voice Output: ElevenLabs TTS (primary), iOS AVSpeechSynthesizer (fallback)
- Execution: Fully on-device (no backend services)

---

## 4. Camera & Mode Switching Requirements

### Camera Usage
- **Driver Mode:** Front (selfie) camera
- **Road Mode:** Rear camera

### Mode Switching
- Switching modes must:
  - stop the active camera session cleanly,
  - reconfigure the camera for the new mode,
  - restart capture without crashing or leaking resources.

Simultaneous dual-camera capture is **NOT required** for the demo.

---

## 5. Driver Mode — Attention & Distraction Monitoring (REQUIRED)

### Inputs
- Live front-camera video frames

### Detection Signals (Must Implement)
1. **Eyes off road / looking down**
   - Based on face orientation / head pose heuristics
2. **Eyes closed too long**
   - Simple eye-closure duration threshold (drowsiness proxy)

Optional (only if trivial):
- Head turned away (yaw threshold)

### Presage Integration (Required, but Scoped)
- Presage is a **first-class input signal**, not an experiment platform.
- Use Presage to provide **one or two simple driver-state signals**, such as:
  - fatigue likelihood
  - attention confidence
- Do NOT implement:
  - long-term baselining
  - personalization
  - historical analysis
  - backend communication

Presage signals should **augment** Vision-based distraction detection, not replace it.

---

## 6. Road Mode — Hazard Detection (REQUIRED)

### Inputs
- Live rear-camera feed
- Often pointed at dashcam footage played on a laptop/tablet during demo

### Object Detection
- Use a pre-trained YOLO-style CoreML model to detect:
  - vehicles
  - pedestrians
  - cyclists (if supported by the model)

### Hazard Heuristics (Must Implement)
1. **Obstacle Ahead**
   - Triggered when a vehicle or person is detected in the forward scene
2. **Closing Fast**
   - Simple heuristic based on rapid growth of a leading vehicle’s bounding box
   - Treated as a proxy for sudden braking / rapid closing distance

Optional only if trivial:
- Lane drift (very lightweight heuristic)

Do NOT implement:
- precise distance estimation
- speed calculation
- path planning
- traffic lights or stop signs

---

## 7. Event-Based Alert System (REQUIRED)

### Event Model
All detections must emit **discrete events**, e.g.:
- DRIVER_DISTRACTED
- DRIVER_DROWSY
- OBSTACLE_AHEAD
- CLOSING_FAST

Continuous narration is explicitly forbidden.

### Alert Orchestration
- Alerts must be:
  - debounced
  - rate-limited (cooldowns per event type)
  - prioritized

### Priority Order
1. Road hazards (obstacle, closing fast)
2. Driver distraction
3. Driver drowsiness

---

## 8. Voice Output (ElevenLabs Is Core)

### Requirements
- ElevenLabs TTS is the **primary alert mechanism**
- Use a **fixed, small phrase set** (≈5–8 phrases total)
- Generate and cache audio locally on first use
- Play cached audio for subsequent alerts
- Fallback to iOS AVSpeechSynthesizer if ElevenLabs fails or is unavailable

### Example Phrases
- “Eyes up.”
- “Watch the road.”
- “You seem drowsy.”
- “Obstacle ahead.”
- “Closing fast.”

---

## 9. UI Requirements (Minimal by Design)

### Must Include
- Live camera preview
- Mode toggle: Driver / Road
- Minimal visual overlays:
  - bounding boxes
  - simple highlights showing what the model sees
- Optional debug text (FPS, last event, confidence) for judges

### Must NOT Include
- Dense UI
- Charts
- Menus beyond what’s necessary
- Explanatory text during alerts

The UI should assist the driver, not distract them.

---

## 10. Latency & Performance Constraints (First-Class)

- End-to-end latency (camera frame → alert) is critical
- Prefer **dropping frames** over buffering or lag
- Target low, stable FPS (e.g. 10–15 FPS)
- Degrade gracefully if performance dips:
  - lower resolution
  - lower inference frequency

No per-frame network calls are allowed.

---

## 11. Testing & Demo Support

### Demo Reality
- The road camera will often be pointed at a screen playing dashcam footage
- This is intentional and acceptable
- All perception must still run on live camera frames

Optional (nice-to-have):
- Ability to switch to a prerecorded video file as a simulated camera source

---

## 12. Explicit Non-Goals (Do NOT Implement)

- No backend or cloud inference
- No analytics dashboards
- No personalization or user accounts
- No GPS or map integration
- No autonomy or ADAS claims
- No continuous explanations or narration
- No simultaneous dual-camera requirement

---

## 13. Definition of Done (Hackathon)

The project is considered complete if:

- A single iOS app runs on a physical iPhone
- The app can switch between Driver Mode and Road Mode
- Each mode triggers **at least two reliable alerts live**
- Voice alerts play consistently
- The demo can be repeated quickly for multiple judges
- The system feels intentional, responsive, and understandable

Anything beyond this is a bonus.

---

## 14. Guiding Principle (For All Implementation Decisions)

If a feature does not directly improve:
- demo reliability,
- latency,
- or clarity to judges,

**do not build it**.
