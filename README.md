# SpeedOCR Studio — Native macOS Screen & OCR Dashboard

[![GitHub Pages](https://img.shields.io/badge/Live_Site-GitHub_Pages-0066FF?style=for-the-badge&logo=github)](https://overandor.github.io/SpeedOCR-Studio/)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS_14.0+-black?style=for-the-badge&logo=apple)](https://github.com/overandor/SpeedOCR-Studio)

**SpeedOCR Studio** is an award-winning native macOS application built with SwiftUI, ScreenCaptureKit, and Vision OCR. It captures full 60+ FPS screen video while performing real-time asynchronous text recognition, featuring an interactive **Screen Lasso Region Selector**, an **Embedded Web View with Auto-Scroll Harvester**, and a live **Transcribing Dashboard**.

---

## 🌐 Live Website & GitHub Repository

- 🌟 **Live Landing Page (GitHub Pages)**: [https://overandor.github.io/SpeedOCR-Studio/](https://overandor.github.io/SpeedOCR-Studio/)
- 📦 **GitHub Repository**: [https://github.com/overandor/SpeedOCR-Studio](https://github.com/overandor/SpeedOCR-Studio)

---

## ⚡ Key Features

- 🎯 **Interactive Screen Lasso**: Click **"Select Region (Lasso)"** to dim the screen and click-and-drag over any region to record *only* what is inside that rectangle.
- 🌐 **Embedded Web Auto-Scroll & Harvester**: Auto-scrolls long web pages/feeds and auto-triggers "Load More" buttons while harvesting text live.
- 📊 **Live Transcribing Dashboard**: Real-time scrolling transcript stream as you record.
- 📋 **One-Click Quick Copy Toolbar**:
  - **Copy All Text**: Copies the complete accumulated transcript.
  - **Copy Clean List**: Copies deduplicated text lines without repeats.
  - **Copy Latest**: Copies text from the most recent OCR frame.
- ⚡ **Asynchronous Change-Driven OCR**: Vision OCR runs only when visual changes are detected on screen, saving CPU.
- 📁 **Automated Exports**: Every session automatically generates `capture.mp4`, `transcript.txt`, `ocr.srt`, and `ocr.jsonl`.

---

## 🚀 How to Run Locally

### Option 1: Double-Click Native App
1. Run `./build_app.command` (or open `SpeedOCR Studio.app`).
2. Double-click `SpeedOCR Studio.app` to open the GUI Dashboard.

### 🛡️ Troubleshooting macOS Gatekeeper ("App is damaged and can't be opened")
Because files downloaded from the web carry macOS quarantine extended attributes, run this one-liner command in Terminal to bypass Gatekeeper:
```bash
xattr -cr "SpeedOCR Studio.app"
```
Or if moved to `/Applications`:
```bash
sudo xattr -rd com.apple.quarantine "/Applications/SpeedOCR Studio.app"
```

### Option 2: Run via Terminal
```bash
./run.command
```

