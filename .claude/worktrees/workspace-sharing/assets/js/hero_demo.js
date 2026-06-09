// Drives the animated five-step landing demo (Submit → Review → Feedback →
// Discuss → Resolve). The home page is a server-rendered dead view, so — like
// legal_toc.js — this is a plain DOM module rather than a LiveView hook. It
// cycles the `data-step` attribute on the `#hero-demo` stage on a timer, keeps
// the step rail in sync, pauses on hover, and lets a rail button jump to a
// specific step. The per-step UI (and the rail labels) carry the meaning, so
// there are no caption pills. No external deps.
//
// Adapted from docs/design/mockups/hero.html's vanilla JS.

// Per-step dwell time, in ms — long enough for each step's choreography to
// finish: Submit (upload), Review (scan), Feedback (overall → 3 cards + the
// matching highlights), Discuss (the thread), Resolve (revisions + polish pass).
const DURATIONS = [3600, 4200, 5800, 6600, 5600];
const STEP_COUNT = DURATIONS.length;
const RESUME_DELAY = 1400;

function runHeroDemo(stage) {
  const steps = Array.from(stage.querySelectorAll(".pp-rail-step"));
  const lines = Array.from(stage.querySelectorAll(".pp-rail-line"));
  let current = -1;
  let timer = null;

  const clear = () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
  };

  const setStep = (i) => {
    current = i;
    stage.setAttribute("data-step", String(i));

    steps.forEach((step, n) => {
      step.classList.toggle("pp-active", n === i);
      step.classList.toggle("pp-done", n < i);
    });

    lines.forEach((line, n) => {
      const fill = line.querySelector("i");
      if (!fill) return;
      line.classList.remove("pp-fillrun");
      // Connector lines before the active step are fully filled.
      fill.style.transform = n < i ? "scaleX(1)" : "scaleX(0)";
    });

    // Animate the connector leaving the active step over its dwell time.
    if (i < lines.length) {
      const line = lines[i];
      line.style.setProperty("--pp-ms", DURATIONS[i] + "ms");
      // Force a reflow so the keyframe restarts each cycle.
      void line.offsetWidth;
      line.classList.add("pp-fillrun");
    }

    clear();
    timer = setTimeout(() => setStep((i + 1) % STEP_COUNT), DURATIONS[i]);
  };

  // Rail clicks jump to a step (and reset the auto-advance from there).
  steps.forEach((step) => {
    step.addEventListener("click", () => {
      const i = Number(step.dataset.i);
      if (!Number.isNaN(i)) setStep(i);
    });
  });

  // Pause on hover, resume shortly after the pointer leaves.
  stage.addEventListener("mouseenter", clear);
  stage.addEventListener("mouseleave", () => {
    clear();
    timer = setTimeout(() => setStep((current + 1) % STEP_COUNT), RESUME_DELAY);
  });

  setStep(0);
}

export default function initHeroDemo() {
  const stage = document.getElementById("hero-demo");
  if (stage) runHeroDemo(stage);
}
