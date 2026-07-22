document.addEventListener('DOMContentLoaded', () => {
  // --- 1. Lasso Sandbox Logic ---
  const canvas = document.getElementById('sandboxCanvas');
  const screen = canvas.querySelector('.simulated-screen');
  const lasso = document.getElementById('lassoBox');
  const dimensions = document.getElementById('lassoDimensions');
  const feed = document.getElementById('sandboxFeed');
  const copyBtn = document.getElementById('copySandboxBtn');

  let isDragging = false;
  let startX = 0, startY = 0;

  screen.addEventListener('mousedown', (e) => {
    const rect = screen.getBoundingClientRect();
    startX = e.clientX - rect.left;
    startY = e.clientY - rect.top;
    isDragging = true;

    lasso.style.left = `${startX}px`;
    lasso.style.top = `${startY}px`;
    lasso.style.width = `0px`;
    lasso.style.height = `0px`;
  });

  screen.addEventListener('mousemove', (e) => {
    if (!isDragging) return;
    const rect = screen.getBoundingClientRect();
    const currentX = Math.max(0, Math.min(rect.width, e.clientX - rect.left));
    const currentY = Math.max(0, Math.min(rect.height, e.clientY - rect.top));

    const left = Math.min(startX, currentX);
    const top = Math.min(startY, currentY);
    const width = Math.abs(currentX - startX);
    const height = Math.abs(currentY - startY);

    lasso.style.left = `${left}px`;
    lasso.style.top = `${top}px`;
    lasso.style.width = `${width}px`;
    lasso.style.height = `${height}px`;
    dimensions.textContent = `${Math.round(width)} × ${Math.round(height)}`;

    updateRecognizedText(width, height);
  });

  document.addEventListener('mouseup', () => { isDragging = false; });

  function updateRecognizedText(width, height) {
    if (width < 20 || height < 20) return;
    let sampleText = [];
    if (height > 60 && width > 100) sampleText.push("const recorder = new SpeedOCRStudio({ fps: 60, ocrFPS: 8 });");
    if (height > 100) sampleText.push("recorder.onTextDetected((event) => { console.log(event.text); });");
    if (height > 140) sampleText.push("SpeedOCR Studio runs Vision OCR asynchronously on video frames.");

    if (sampleText.length > 0) {
      const timestamp = new Date().toLocaleTimeString();
      feed.innerHTML = `
        <div style="color: #00F2FE; margin-bottom: 6px;">[${timestamp}] Detected Text (${Math.round(width)}×${Math.round(height)}):</div>
        <div>${sampleText.join('<br>')}</div>
      `;
    }
  }

  copyBtn.addEventListener('click', () => {
    const text = feed.innerText;
    if (text && !text.includes('Drag over text')) {
      navigator.clipboard.writeText(text);
      copyBtn.textContent = '✓ Copied!';
      setTimeout(() => { copyBtn.textContent = '📋 Copy Output'; }, 2000);
    }
  });

  // --- 2. Embedded Web Auto-Scroll & Harvester Engine ---
  const viewport = document.getElementById('embeddedViewport');
  const btnAutoScroll = document.getElementById('btnAutoScroll');
  const autoScrollIcon = document.getElementById('autoScrollIcon');
  const autoScrollText = document.getElementById('autoScrollText');
  const harvestedFeed = document.getElementById('harvestedFeed');
  const btnCopyHarvest = document.getElementById('btnCopyHarvest');
  const btnLoadMore = document.getElementById('btnLoadMore');
  const hiddenContent = document.getElementById('hiddenContent');

  let autoScrollTimer = null;
  let isAutoScrolling = false;
  let harvestedLines = new Set([
    "Regional Data Trends & Economic Indicator Report",
    "SECTOR: Agriculture +4.2% Export Value: R 18.5 Billion"
  ]);

  btnAutoScroll.addEventListener('click', () => {
    if (isAutoScrolling) {
      stopAutoScroll();
    } else {
      startAutoScroll();
    }
  });

  function startAutoScroll() {
    isAutoScrolling = true;
    btnAutoScroll.classList.remove('btn-primary');
    btnAutoScroll.classList.add('btn-secondary');
    autoScrollIcon.textContent = '⏸';
    autoScrollText.textContent = 'Pause Auto-Scroll';

    autoScrollTimer = setInterval(() => {
      viewport.scrollTop += 24;

      // Auto-trigger Load More button when scrolled near bottom
      if (btnLoadMore && !hiddenContent.classList.contains('visible')) {
        const rect = btnLoadMore.getBoundingClientRect();
        const vRect = viewport.getBoundingClientRect();
        if (rect.top <= vRect.bottom - 40) {
          btnLoadMore.click();
        }
      }

      // Check text content under scroll and capture OCR lines
      captureScrolledText();

      // Loop back to top if reached end
      if (viewport.scrollTop + viewport.clientHeight >= viewport.scrollHeight - 10) {
        setTimeout(() => { viewport.scrollTop = 0; }, 1200);
      }
    }, 150);
  }

  function stopAutoScroll() {
    isAutoScrolling = false;
    clearInterval(autoScrollTimer);
    btnAutoScroll.classList.remove('btn-secondary');
    btnAutoScroll.classList.add('btn-primary');
    autoScrollIcon.textContent = '▶';
    autoScrollText.textContent = 'Auto-Scroll & Capture';
  }

  btnLoadMore.addEventListener('click', () => {
    hiddenContent.classList.add('visible');
    btnLoadMore.style.display = 'none';
    addHarvestItem("Expanded Records Loaded: Investments R 15.2B in Q2 2026.");
  });

  function captureScrolledText() {
    const scrollPos = viewport.scrollTop;

    if (scrollPos > 80 && !harvestedLines.has("Mining & Minerals +2.8% Export Value: R 42.1 Billion")) {
      addHarvestItem("Mining & Minerals +2.8% Export Value: R 42.1 Billion");
    }
    if (scrollPos > 160 && !harvestedLines.has("Renewable Energy +14.6% Export Value: R 9.3 Billion")) {
      addHarvestItem("Renewable Energy +14.6% Export Value: R 9.3 Billion");
    }
    if (scrollPos > 240 && !harvestedLines.has("Financial Technology +18.9% Export Value: R 12.7 Billion")) {
      addHarvestItem("Financial Technology +18.9% Export Value: R 12.7 Billion");
    }
    if (scrollPos > 320 && hiddenContent.classList.contains('visible') && !harvestedLines.has("Telecommunications coverage expanded to 98% 5G density")) {
      addHarvestItem("Telecommunications coverage expanded to 98% 5G density");
    }
  }

  function addHarvestItem(text) {
    harvestedLines.add(text);
    const timeStr = new Date().toLocaleTimeString().slice(3, 8);
    const item = document.createElement('div');
    item.className = 'harvest-item';
    item.innerHTML = `<span class="timestamp">[${timeStr}]</span> ${text}`;
    harvestedFeed.appendChild(item);
    harvestedFeed.scrollTop = harvestedFeed.scrollHeight;
  }

  btnCopyHarvest.addEventListener('click', () => {
    const text = Array.from(harvestedLines).join('\n');
    navigator.clipboard.writeText(text);
    btnCopyHarvest.textContent = '✓ Copied!';
    setTimeout(() => { btnCopyHarvest.textContent = '📋 Copy All'; }, 2000);
  });
});
