// Scroll-spy + back-to-top for long-form legal/policy pages (terms, privacy).
//
// These pages are server-rendered dead views, so this is a plain DOM module
// rather than a LiveView hook. It keeps the table-of-contents link for the
// section currently in view marked with `aria-current="true"` (styled via the
// `aria-[current=true]:` Tailwind variants on `[data-toc-link]`), and reveals a
// floating back-to-top control once the reader has scrolled down.

function tocLinkId(link) {
  return decodeURIComponent((link.getAttribute("href") || "").replace(/^#/, ""));
}

function initTocSpy() {
  const links = Array.from(document.querySelectorAll("[data-toc-link]"));
  if (links.length === 0) return;

  // Desktop rail and mobile disclosure share section ids — one observer drives both.
  const ids = new Set(links.map(tocLinkId).filter(Boolean));
  const sections = Array.from(ids)
    .map((id) => document.getElementById(id))
    .filter(Boolean);
  if (sections.length === 0) return;

  let activeId = null;
  const setActive = (id) => {
    if (!id || id === activeId) return;
    activeId = id;
    links.forEach((link) => {
      if (tocLinkId(link) === id) {
        link.setAttribute("aria-current", "true");
      } else {
        link.removeAttribute("aria-current");
      }
    });
  };

  const observer = new IntersectionObserver(
    (entries) => {
      const visible = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
      if (visible.length > 0) setActive(visible[0].target.id);
    },
    // Activate a section once its heading reaches the upper third of the viewport.
    { rootMargin: "-20% 0px -70% 0px", threshold: 0 }
  );
  sections.forEach((section) => observer.observe(section));

  // Tapping a link on mobile closes the disclosure so the jump target is visible.
  links.forEach((link) => {
    link.addEventListener("click", () => {
      const details = link.closest("details.collapse");
      if (details) details.removeAttribute("open");
    });
  });
}

function initBackToTop() {
  const fab = document.querySelector("[data-back-to-top]");
  if (!fab) return;
  const button = fab.querySelector("button") || fab;

  const sync = () => {
    if (window.scrollY > 600) {
      fab.removeAttribute("hidden");
    } else {
      fab.setAttribute("hidden", "");
    }
  };

  button.addEventListener("click", () => {
    window.scrollTo({ top: 0, behavior: "smooth" });
  });
  window.addEventListener("scroll", sync, { passive: true });
  sync();
}

export default function initLegalPages() {
  initTocSpy();
  initBackToTop();
}
