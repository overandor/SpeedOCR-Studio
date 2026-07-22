# SpeedOCR Studio — Native macOS Screen & OCR Dashboard

**SpeedOCR Studio** is a native macOS application built with SwiftUI, ScreenCaptureKit, and Vision OCR. It captures full 60+ FPS screen video while performing real-time asynchronous text recognition, featuring an interactive **Screen Lasso Region Selector** and a live **Transcribing Dashboard**.

---

## ⚡ Key Features

- 🎯 **Interactive Screen Lasso**: Click **"Select Region (Lasso)"** to dim the screen and click-and-drag over any region to record *only* what is inside that rectangle.
- 📊 **Live Transcribing Dashboard**: Real-time scrolling transcript stream as you record.
- 📋 **One-Click Quick Copy Toolbar**:
  - **Copy All Text**: Copies the complete accumulated transcript.
  - **Copy Clean List**: Copies deduplicated text lines without repeats.
  - **Copy Latest**: Copies text from the most recent OCR frame.
- ⚡ **Asynchronous Change-Driven OCR**: Vision OCR runs only when visual changes are detected on screen, saving CPU.
- 📁 **Automated Exports**: Every session automatically generates:
  - `capture.mp4`: Full-speed video stream.
  - `transcript.txt`: Plain-text clean transcription.
  - `ocr.srt`: Subtitle file with precise timestamps.
  - `ocr.jsonl`: Machine-readable bounding boxes & confidence scores.

---

## 🚀 How to Run

### Option 1: Double-Click Native App
1. Run `./build_app.command` (or open `SpeedOCR Studio.app`).
2. Double-click `SpeedOCR Studio.app` to open the GUI Dashboard.

### Option 2: Run via Terminal
```bash
./run.command
```

---

## 🔒 Permissions
On first launch, macOS will prompt for **Screen Recording** permission under:
**System Settings → Privacy & Security → Screen & System Audio Recording**.
EOF
