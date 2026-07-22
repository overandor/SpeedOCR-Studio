document.addEventListener('DOMContentLoaded', () => {
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

  document.addEventListener('mouseup', () => {
    isDragging = false;
  });

  function updateRecognizedText(width, height) {
    if (width < 20 || height < 20) return;

    let sampleText = [];
    if (height > 60 && width > 100) {
      sampleText.push("const recorder = new SpeedOCRStudio({ fps: 60, ocrFPS: 8 });");
    }
    if (height > 100) {
      sampleText.push("recorder.onTextDetected((event) => { console.log(event.text); });");
    }
    if (height > 140) {
      sampleText.push("SpeedOCR Studio runs Vision OCR asynchronously on video frames.");
    }

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
      setTimeout(() => {
        copyBtn.textContent = '📋 Copy Output';
      }, 2000);
    }
  });
});
