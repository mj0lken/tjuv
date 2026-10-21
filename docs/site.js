// Tjuv landing page: copy buttons, compatibility check, and scroll tour (laptop opens → desktop → panel tour).
(() => {
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (/mac|iphone|ipad/i.test(navigator.userAgentData?.platform || navigator.platform || "")) {
    document.documentElement.classList.add("apple-os");
  }

  document.querySelectorAll("button[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        button.textContent = "Copied";
        button.classList.add("copied");
      } catch {
        button.textContent = "Press ⌘C";
      }
      setTimeout(() => {
        button.textContent = "Copy";
        button.classList.remove("copied");
      }, 1800);
    });
  });

  setUpCompatibilityCheck();

  const intro = document.querySelector(".intro");
  if (!intro || reducedMotion) return;

  const stage = intro.querySelector(".intro-sticky");
  const copy = intro.querySelector(".intro-copy");
  const canvas = intro.querySelector(".scene-canvas");
  const desktop = intro.querySelector(".desktop");
  const panelWrap = intro.querySelector(".panel-wrap");
  const icon = intro.querySelector(".mb-icon");
  const cursor = intro.querySelector(".cursor");
  const dots = [...intro.querySelectorAll(".tour-progress i")];

  intro.classList.add("is-live");

  const PHASE = { open: [0.02, 0.13], zoom: [0.13, 0.23], reveal: [0.205, 0.245], point: [0.245, 0.285], click: 0.29, tour: [0.3, 0.985] };
  const STEPS = 6;

  const clamp01 = (v) => Math.min(1, Math.max(0, v));
  const progressIn = ([from, to], p) => clamp01((p - from) / (to - from));
  const ease = (t) => 1 - Math.pow(1 - t, 3);
  const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const mix = (a, b, t) => a + (b - a) * t;

  let geometry = null;
  let laptopView = null;
  let laptopState = "idle";
  const previewParam = new URLSearchParams(location.search).get("preview");
  const preview = previewParam !== null && Number(previewParam) >= 0 && Number(previewParam) <= 1 ? Number(previewParam) : null;

  function loadLaptop() {
    laptopState = "loading";
    const preload = document.createElement("link");
    preload.rel = "modulepreload";
    preload.href = "vendor/three/three.module.min.js";
    document.head.append(preload);
    import("./laptop3d.js")
      .then(({ createLaptopView }) => {
        laptopView = createLaptopView(canvas);
        laptopState = "ready";
        geometry = null;
        requestRender();
      })
      .catch(disableLaptop);
  }

  function disableLaptop(error) {
    console.warn("Tjuv: 3D laptop unavailable, skipping it.", error);
    laptopView?.dispose();
    laptopView = null;
    laptopState = "failed";
    intro.classList.add("no-laptop");
    requestRender();
  }

  function measure() {
    const vw = stage.clientWidth;
    const vh = stage.clientHeight;
    const narrow = vw <= 980;
    const copyBottom = copy.offsetTop + copy.offsetHeight;
    laptopView?.resize({ width: vw, height: vh, copyBottom });

    const iconRect = icon.getBoundingClientRect();
    const panelWidth = panelWrap.offsetHeight * (684 / 1192);
    const panelLeft = narrow
      ? (vw - panelWidth) / 2
      : Math.min(vw - panelWidth - 16, Math.max(16, iconRect.left + iconRect.width / 2 - panelWidth / 2));
    panelWrap.style.left = `${panelLeft}px`;
    panelWrap.style.width = `${panelWidth}px`;

    geometry = {
      vw, vh,
      cursorFrom: { x: vw * 0.42, y: vh * 0.62 },
      cursorTo: { x: iconRect.left + iconRect.width / 2 - 4, y: iconRect.top + iconRect.height / 2 - 2 },
    };
  }

  function render() {
    ticking = false;
    if (!geometry) measure();
    const g = geometry;
    const rect = intro.getBoundingClientRect();
    const scrollable = intro.offsetHeight - g.vh;
    const scrolled = preview ?? clamp01(-rect.top / scrollable);
    const skipLaptop = laptopState === "failed";
    const p = skipLaptop ? mix(PHASE.reveal[0] - 0.03, 1, scrolled) : scrolled;
    intro.dataset.progress = p.toFixed(3);

    const inLaptopPart = p < PHASE.reveal[1] + 0.02;
    if (inLaptopPart && laptopState === "idle") loadLaptop();
    if (inLaptopPart && laptopView) {
      try {
        laptopView.update({ open: easeInOut(progressIn(PHASE.open, p)), zoom: easeInOut(progressIn(PHASE.zoom, p)) });
      } catch (error) {
        disableLaptop(error);
      }
    }

    const copyT = progressIn(skipLaptop ? [0.0, 0.04] : [0.0, 0.055], scrolled);
    copy.style.opacity = String(1 - ease(copyT));
    copy.style.transform = `translateY(${-90 * ease(copyT)}px) scale(${1 - 0.06 * ease(copyT)})`;
    copy.style.visibility = copyT >= 1 ? "hidden" : "visible";

    const reveal = progressIn(PHASE.reveal, p);
    desktop.style.opacity = String(reveal);
    desktop.classList.toggle("is-visible", reveal > 0);
    canvas.style.opacity = String(1 - progressIn([PHASE.reveal[1] - 0.01, PHASE.reveal[1] + 0.01], p));
    document.body.classList.toggle("story-playing", p > PHASE.open[0] && p < 0.995);

    const point = easeInOut(progressIn(PHASE.point, p));
    const clicked = p >= PHASE.click;
    const press = clicked && p < PHASE.click + 0.008 ? 0.85 : 1;
    const cx = mix(g.cursorFrom.x, g.cursorTo.x, point);
    const cy = mix(g.cursorFrom.y, g.cursorTo.y, point);
    cursor.style.transform = `translate(${cx}px, ${cy}px) scale(${press})`;
    cursor.style.opacity = String(Math.min(progressIn([PHASE.point[0] - 0.01, PHASE.point[0]], p), 1 - progressIn([PHASE.click + 0.02, PHASE.click + 0.035], p)));
    desktop.classList.toggle("panel-open", clicked);

    const tourT = progressIn(PHASE.tour, p);
    const step = clicked ? Math.min(STEPS - 1, Math.floor(tourT * STEPS)) : -1;
    if (desktop.dataset.step !== String(step)) {
      desktop.dataset.step = String(step);
      dots.forEach((dot, index) => dot.classList.toggle("is-current", index === step));
    }
  }

  let ticking = false;
  const requestRender = () => {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(render);
    }
  };
  window.addEventListener("scroll", requestRender, { passive: true });
  window.addEventListener("resize", () => { geometry = null; requestRender(); });

  render();

  function setUpCompatibilityCheck() {
    const root = document.getElementById("compat");
    if (!root) return;
    const button = root.querySelector(".compat-button");
    const result = root.querySelector(".compat-result");
    const verdict = root.querySelector(".compat-verdict");
    const list = root.querySelector(".compat-list");
    const terminal = root.querySelector(".compat-terminal");
    const MIN_MACOS = 15;

    button.addEventListener("click", async () => {
      button.disabled = true;
      const checks = await runChecks();
      render(checks);
      button.disabled = false;
      button.textContent = "Check again";
    });

    async function runChecks() {
      const ua = navigator.userAgent;
      const hints = navigator.userAgentData;
      const platform = hints?.platform || navigator.platform || "";
      const isIPad = /Macintosh/.test(ua) && navigator.maxTouchPoints > 1;
      const isMac = /mac/i.test(platform) && !isIPad;

      let architecture = null;
      let macVersion = null;
      if (hints?.getHighEntropyValues) {
        try {
          const values = await hints.getHighEntropyValues(["architecture", "platformVersion"]);
          architecture = values.architecture || null;
          macVersion = values.platformVersion || null;
        } catch { /* fallback below */ }
      }

      const gpu = graphicsRenderer();
      const chipMatch = gpu && gpu.match(/Apple (M\d+(?: (?:Pro|Max|Ultra))?)/);
      let silicon = { tone: "unknown", detail: "Your browser doesn't say which chip you have." };
      if (architecture === "arm" || chipMatch) {
        silicon = { tone: "pass", detail: chipMatch ? `Apple ${chipMatch[1]} (SPU IMU supported)` : "Apple Silicon" };
      } else if (architecture === "x86" || (gpu && /Intel|AMD|Radeon|NVIDIA/i.test(gpu))) {
        silicon = { tone: "fail", detail: "This looks like an Intel Mac. Tjuv needs an Apple Silicon MacBook (M1 or later) for the 800 Hz SPU motion sensor." };
      } else if (gpu && /Apple GPU/i.test(gpu)) {
        silicon = { tone: "pass", detail: "Apple GPU, so almost certainly Apple Silicon." };
      }

      let macOS = { tone: "unknown", detail: "Your browser hides the macOS version." };
      const major = macVersion ? parseInt(macVersion, 10) : NaN;
      if (Number.isFinite(major) && major >= 10) {
        macOS = major >= MIN_MACOS
          ? { tone: "pass", detail: `macOS ${macVersion.replace(/\.0$/, "")}` }
          : { tone: "fail", detail: `macOS ${macVersion}. Tjuv needs macOS ${MIN_MACOS} or later.` };
      }

      return { isMac, silicon, macOS };
    }

    function graphicsRenderer() {
      try {
        const gl = document.createElement("canvas").getContext("webgl");
        if (!gl) return null;
        const info = gl.getExtension("WEBGL_debug_renderer_info");
        return String(gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER));
      } catch {
        return null;
      }
    }

    function render({ isMac, silicon, macOS }) {
      list.replaceChildren();
      result.hidden = false;
      if (!isMac) {
        setVerdict("fail", "This isn't a Mac. Open this page on your MacBook to check it.");
        terminal.hidden = true;
        return;
      }
      addRow("pass", "A Mac", "Tjuv is a macOS menu bar app.");
      addRow(silicon.tone, "Apple Silicon (SPU IMU)", silicon.detail);
      addRow(macOS.tone, `macOS ${MIN_MACOS} or later`, macOS.detail);

      const tones = [silicon.tone, macOS.tone];
      if (tones.includes("fail")) {
        setVerdict("fail", "Not compatible, sorry.");
      } else if (tones.includes("unknown")) {
        setVerdict("unknown", "Probably fine. Confirm the details below.");
      } else {
        setVerdict("pass", "Good to go. Ready to arm!");
      }
      terminal.hidden = !tones.includes("unknown");
    }

    function setVerdict(tone, text) {
      verdict.dataset.tone = tone;
      verdict.textContent = text;
    }

    function addRow(tone, title, detail) {
      const item = document.createElement("li");
      const icon = document.createElement("span");
      icon.className = "compat-icon";
      icon.dataset.tone = tone;
      icon.textContent = tone === "pass" ? "✓" : tone === "fail" ? "✕" : "?";
      icon.setAttribute("aria-label", tone === "pass" ? "Yes" : tone === "fail" ? "No" : "Unknown");
      const text = document.createElement("div");
      const strong = document.createElement("strong");
      strong.textContent = title;
      const small = document.createElement("span");
      small.className = "detail";
      small.textContent = detail;
      text.append(strong, small);
      item.append(icon, text);
      list.append(item);
    }
  }
})();
