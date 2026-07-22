# SpeedOCR Studio — Native macOS Screen & OCR Dashboard

**SpeedOCR Studio** is a native macOS application built with SwiftUI, ScreenCaptureKit, and Vision OCR. It captures full 60+ FPS screen video while performing real-time asynchronous text recognition, featuring an interactive **Screen Lasso Region Selector**, an **Embedded Web View with Auto-Scroll Harvester**, and a live **Transcribing Dashboard**.

---

## 🚀 Deployment (Vercel & GitHub Pages)

The landing page web app (`website/`) is pre-configured for 1-click deployment on both **Vercel** and **GitHub Pages**.

### 1. Deploy on Vercel
Click below to deploy directly to Vercel, or connect your GitHub repository in your Vercel Dashboard:

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/git/external?repository-url=https://github.com)

*Note: `vercel.json` automatically routes static traffic to `website/`.*

### 2. Deploy on GitHub Pages
This repository includes an automated GitHub Action workflow (`.github/workflows/deploy.yml`):

1. Push your repository to GitHub.
2. Go to **Repository Settings → Pages**.
3. Set **Source** to **GitHub Actions**.
4. Every push to `main` will automatically build and publish your landing page to `https://<your-username>.github.io/<repo-name>/`!

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

### Option 2: Run via Terminal
```bash
./run.command
```
