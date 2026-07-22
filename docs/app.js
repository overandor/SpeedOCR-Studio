document.addEventListener('DOMContentLoaded', () => {
  // --- 1. Canvas Background Particles ---
  const canvas = document.getElementById('particleCanvas');
  const ctx = canvas.getContext('2d');
  let width = canvas.width = window.innerWidth;
  let height = canvas.height = window.innerHeight;

  window.addEventListener('resize', () => {
    width = canvas.width = window.innerWidth;
    height = canvas.height = window.innerHeight;
  });

  const particles = Array.from({ length: 45 }, () => ({
    x: Math.random() * width,
    y: Math.random() * height,
    vx: (Math.random() - 0.5) * 0.4,
    vy: (Math.random() - 0.5) * 0.4,
    radius: Math.random() * 2 + 1,
    alpha: Math.random() * 0.4 + 0.1
  }));

  function drawParticles() {
    ctx.clearRect(0, 0, width, height);
    particles.forEach(p => {
      p.x += p.vx;
      p.y += p.vy;
      if (p.x < 0) p.x = width; if (p.x > width) p.x = 0;
      if (p.y < 0) p.y = height; if (p.y > height) p.y = 0;

      ctx.beginPath();
      ctx.arc(p.x, p.y, p.radius, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(0, 102, 255, ${p.alpha})`;
      ctx.fill();
    });
    requestAnimationFrame(drawParticles);
  }
  drawParticles();

  // --- 2. 3D Window Tilt Effect ---
  const tiltContainer = document.getElementById('tiltContainer');
  const appWindow = document.getElementById('appWindow');

  if (tiltContainer && appWindow) {
    tiltContainer.addEventListener('mousemove', (e) => {
      const rect = tiltContainer.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;
      const centerX = rect.width / 2;
      const centerY = rect.height / 2;

      const rotateX = ((y - centerY) / centerY) * -8;
      const rotateY = ((x - centerX) / centerX) * 8;

      appWindow.style.transform = `rotateX(${rotateX}deg) rotateY(${rotateY}deg) scale3d(1.02, 1.02, 1.02)`;
    });

    tiltContainer.addEventListener('mouseleave', () => {
      appWindow.style.transform = `rotateX(0deg) rotateY(0deg) scale3d(1, 1, 1)`;
    });
  }

  // --- 3. Animated Metric Counters ---
  const metricCards = document.querySelectorAll('.metric-number');
  let animated = false;

  function checkMetricsScroll() {
    if (animated) return;
    const triggerBottom = window.innerHeight * 0.85;
    metricCards.forEach(card => {
      const top = card.getBoundingClientRect().top;
      if (top < triggerBottom) {
        animated = true;
        const target = parseInt(card.getAttribute('data-target'));
        if (target === 0) { card.textContent = "0"; return; }

        let count = 0;
        const step = Math.ceil(target / 40);
        const timer = setInterval(() => {
          count += step;
          if (count >= target) {
            card.textContent = target;
            clearInterval(timer);
          } else {
            card.textContent = count;
          }
        }, 30);
      }
    });
  }
  window.addEventListener('scroll', checkMetricsScroll);
  checkMetricsScroll();

  // --- 4. Multi-Mode Sandbox Tabs ---
  const tabBtns = document.querySelectorAll('.tab-btn');
  const tabContents = document.querySelectorAll('.tab-content');

  tabBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      tabBtns.forEach(b => b.classList.remove('active'));
      tabContents.forEach(c => c.classList.remove('active'));

      btn.classList.add('active');
      const tabId = `tab-${btn.getAttribute('data-tab')}`;
      document.getElementById(tabId)?.classList.add('active');
    });
  });

  // --- 5. Sandbox 1: Lasso Crop Logic ---
  const screen = document.getElementById('simulatedScreen');
  const lasso = document.getElementById('lassoBox');
  const dimensions = document.getElementById('lassoDimensions');
  const lassoFeed = document.getElementById('lassoFeed');
  const btnCopyLasso = document.getElementById('btnCopyLasso');

  let isDragging = false, startX = 0, startY = 0;

  if (screen) {
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

      if (width > 30 && height > 30) {
        const time = new Date().toLocaleTimeString();
        lassoFeed.innerHTML = `
          <div style="color: #00F2FE; margin-bottom: 6px;">[${time}] Recognized Lasso Region (${Math.round(width)}×${Math.round(height)}):</div>
          <div>import ScreenCaptureKit<br>let config = SCStreamConfiguration()<br>config.sourceRect = CGRect(x: ${Math.round(left)}, y: ${Math.round(top)}, width: ${Math.round(width)}, height: ${Math.round(height)})</div>
        `;
      }
    });

    document.addEventListener('mouseup', () => { isDragging = false; });
  }

  btnCopyLasso?.addEventListener('click', () => {
    navigator.clipboard.writeText(lassoFeed.innerText);
    btnCopyLasso.textContent = '✓ Copied!';
    setTimeout(() => { btnCopyLasso.textContent = '📋 Copy Text'; }, 2000);
  });

  // --- 6. Sandbox 2: Auto-Scroll Engine ---
  const viewport = document.getElementById('embeddedViewport');
  const btnAutoScroll = document.getElementById('btnAutoScroll');
  const autoScrollIcon = document.getElementById('autoScrollIcon');
  const autoScrollText = document.getElementById('autoScrollText');
  const harvestedFeed = document.getElementById('harvestedFeed');
  const btnCopyHarvest = document.getElementById('btnCopyHarvest');
  const btnLoadMore = document.getElementById('btnLoadMore');
  const hiddenContent = document.getElementById('hiddenContent');

  let autoScrollTimer = null, isAutoScrolling = false;

  btnAutoScroll?.addEventListener('click', () => {
    if (isAutoScrolling) {
      isAutoScrolling = false;
      clearInterval(autoScrollTimer);
      btnAutoScroll.classList.remove('btn-secondary');
      btnAutoScroll.classList.add('btn-primary');
      autoScrollIcon.textContent = '▶';
      autoScrollText.textContent = 'Auto-Scroll & Capture';
    } else {
      isAutoScrolling = true;
      btnAutoScroll.classList.remove('btn-primary');
      btnAutoScroll.classList.add('btn-secondary');
      autoScrollIcon.textContent = '⏸';
      autoScrollText.textContent = 'Pause Auto-Scroll';

      autoScrollTimer = setInterval(() => {
        viewport.scrollTop += 24;
        if (btnLoadMore && !hiddenContent.classList.contains('visible')) {
          const rect = btnLoadMore.getBoundingClientRect();
          const vRect = viewport.getBoundingClientRect();
          if (rect.top <= vRect.bottom - 20) btnLoadMore.click();
        }
        if (viewport.scrollTop + viewport.clientHeight >= viewport.scrollHeight - 10) {
          setTimeout(() => { viewport.scrollTop = 0; }, 1000);
        }
      }, 150);
    }
  });

  btnLoadMore?.addEventListener('click', () => {
    hiddenContent.classList.add('visible');
    btnLoadMore.style.display = 'none';
    const item = document.createElement('div');
    item.className = 'harvest-item';
    item.innerHTML = `<span class="timestamp">[00:04.2]</span> Infrastructure investment reached R 15.2B in Q2 2026.`;
    harvestedFeed.appendChild(item);
  });

  btnCopyHarvest?.addEventListener('click', () => {
    navigator.clipboard.writeText(harvestedFeed.innerText);
    btnCopyHarvest.textContent = '✓ Copied!';
    setTimeout(() => { btnCopyHarvest.textContent = '📋 Copy All'; }, 2000);
  });

  // --- 7. Sandbox 3: Multi-Format Exporter ---
  const formatBtns = document.querySelectorAll('.format-btn');
  const codeView = document.getElementById('exportCodeView');
  const btnCopyExport = document.getElementById('btnCopyExport');

  const exportTemplates = {
    txt: `[00:01.4] SpeedOCR Studio: Real-time 60 FPS screen OCR engine\n[00:03.8] Interactive lasso sub-region crop active: 768 x 1,199 pixels.\n[00:06.2] Sector: Agriculture +4.2% Export Value: R 18.5 Billion`,
    srt: `1\n00:00:01,400 --> 00:00:03,800\nSpeedOCR Studio: Real-time 60 FPS screen OCR engine\n\n2\n00:00:03,800 --> 00:00:06,200\nInteractive lasso sub-region crop active: 768 x 1,199 pixels.`,
    jsonl: `{"elapsedSeconds":1.4,"text":"SpeedOCR Studio: Real-time 60 FPS screen OCR engine","boxes":[{"text":"SpeedOCR","x":0.12,"y":0.45}]}\n{"elapsedSeconds":3.8,"text":"Interactive lasso sub-region crop active: 768 x 1,199 pixels.","boxes":[{"text":"Lasso","x":0.22,"y":0.55}]}`
  };

  formatBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      formatBtns.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const fmt = btn.getAttribute('data-fmt');
      if (codeView && exportTemplates[fmt]) {
        codeView.textContent = exportTemplates[fmt];
      }
    });
  });

  btnCopyExport?.addEventListener('click', () => {
    navigator.clipboard.writeText(codeView.textContent);
    btnCopyExport.textContent = '✓ Copied Formatted Code!';
    setTimeout(() => { btnCopyExport.textContent = '📋 Copy Formatted File'; }, 2000);
  });
});
