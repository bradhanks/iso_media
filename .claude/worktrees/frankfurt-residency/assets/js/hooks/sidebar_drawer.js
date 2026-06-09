// Owns the signed-in sidebar's collapse state.
//
// Desktop "collapsed" rail: a `data-collapsed="true"` attribute on `#app-shell`
// (read by `group-data-[collapsed=true]/shell:` variants). The header toggle
// `#app-collapse-toggle` flips it; this hook persists the choice and — crucially
// — re-applies it on mount and after every LiveView patch/navigation, so
// clicking a nav item never resets the rail to full width. Only the toggle
// changes the width.
//
// Mobile: there is no rail; the drawer is kept closed by default and the
// hamburger / dock drive navigation.
//
// localStorage key "pp:sidebar-collapsed": "1" = collapsed rail.
const KEY = "pp:sidebar-collapsed"
const DESKTOP = "(min-width: 1024px)"

const SidebarDrawer = {
  mounted() {
    this.drawerToggle = this.el.querySelector("#app-drawer-toggle")

    // Delegated click — survives re-renders of the header/button across nav.
    this.onClick = (event) => {
      if (event.target.closest && event.target.closest("#app-collapse-toggle")) {
        this.setCollapsed(this.el.getAttribute("data-collapsed") !== "true")
      }
    }
    this.el.addEventListener("click", this.onClick)

    this.apply()
  },

  updated() {
    // LiveView just patched the shell — restore the rail width from storage
    // instead of letting the server-rendered (expanded) markup win.
    this.apply()
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
  },

  apply() {
    if (!window.matchMedia(DESKTOP).matches) {
      // Mobile: no rail; keep the drawer closed by default.
      if (this.drawerToggle) this.drawerToggle.checked = false
      this.reflectCollapsed(false)
      return
    }
    let collapsed = false
    try {
      collapsed = localStorage.getItem(KEY) === "1"
    } catch (_e) {}
    this.reflectCollapsed(collapsed)
  },

  setCollapsed(collapsed) {
    this.reflectCollapsed(collapsed)
    try {
      localStorage.setItem(KEY, collapsed ? "1" : "0")
    } catch (_e) {}
  },

  reflectCollapsed(collapsed) {
    if (collapsed) {
      this.el.setAttribute("data-collapsed", "true")
    } else {
      this.el.removeAttribute("data-collapsed")
    }
  },
}

export default SidebarDrawer
