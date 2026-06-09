// PaneResize — drag the divider between the document and feedback panes to
// resize the document pane. The width is stored as a `--doc-basis` percentage
// on the container and persisted to localStorage, so it survives reloads and
// LiveView navigation. Arrow keys nudge it for keyboard users.
const KEY = "pp:doc-basis"
const MIN = 28
const MAX = 72

const clamp = (pct) => Math.max(MIN, Math.min(MAX, pct))

const PaneResize = {
  mounted() {
    this.handle = this.el.querySelector("[data-resize-handle]")
    if (!this.handle) return

    try {
      const saved = localStorage.getItem(KEY)
      if (saved) this.el.style.setProperty("--doc-basis", saved)
    } catch (_e) {}

    this.dragging = false

    this.onDown = (e) => {
      e.preventDefault()
      this.dragging = true
      document.body.style.cursor = "col-resize"
      this.el.classList.add("select-none")
    }

    this.onMove = (e) => {
      if (!this.dragging) return
      const rect = this.el.getBoundingClientRect()
      if (rect.width === 0) return
      this.setBasis(((e.clientX - rect.left) / rect.width) * 100)
    }

    this.onUp = () => {
      if (!this.dragging) return
      this.dragging = false
      document.body.style.cursor = ""
      this.el.classList.remove("select-none")
      this.persist()
    }

    this.onKey = (e) => {
      const step = e.key === "ArrowLeft" ? -2 : e.key === "ArrowRight" ? 2 : 0
      if (step === 0) return
      e.preventDefault()
      const current = parseFloat(getComputedStyle(this.el).getPropertyValue("--doc-basis")) || 50
      this.setBasis(current + step)
      this.persist()
    }

    this.handle.addEventListener("pointerdown", this.onDown)
    this.handle.addEventListener("keydown", this.onKey)
    window.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
  },

  setBasis(pct) {
    this.el.style.setProperty("--doc-basis", clamp(pct).toFixed(2) + "%")
  },

  persist() {
    try {
      const value = getComputedStyle(this.el).getPropertyValue("--doc-basis").trim()
      if (value) localStorage.setItem(KEY, value)
    } catch (_e) {}
  },

  destroyed() {
    window.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
  },
}

export default PaneResize
