// FitText — shrink a title's font-size until the full text fits within two
// lines, so a long manuscript title reads without being truncated. The element
// carrying the hook holds a `[data-fit]` child (or is itself the text). A CSS
// `line-clamp-2` stays as a final safety net at the minimum size. Re-fits on
// every LiveView update and on viewport resize. No animation, so reduced-motion
// is irrelevant here.
const MAX_PX = 15
const MIN_PX = 10.5

const FitText = {
  mounted() {
    this.target = this.el.querySelector("[data-fit]") || this.el
    this.fit = this.fit.bind(this)
    this.fit()
    this._onResize = () => window.requestAnimationFrame(this.fit)
    window.addEventListener("resize", this._onResize)
  },

  updated() {
    this.target = this.el.querySelector("[data-fit]") || this.el
    this.fit()
  },

  destroyed() {
    window.removeEventListener("resize", this._onResize)
  },

  fit() {
    const el = this.target
    if (!el) return

    // Measure unclamped so we can shrink to fit rather than ellipsize.
    const prevClamp = el.style.webkitLineClamp
    el.style.webkitLineClamp = "unset"

    let size = MAX_PX
    el.style.fontSize = size + "px"

    let guard = 0
    while (size > MIN_PX && guard++ < 40) {
      const lh = parseFloat(getComputedStyle(el).lineHeight) || size * 1.25
      if (el.scrollHeight <= lh * 2 + 1) break
      size -= 0.5
      el.style.fontSize = size + "px"
    }

    // Restore the two-line clamp as a safety net for the worst case.
    el.style.webkitLineClamp = prevClamp || "2"
  },
}

export default FitText
