// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/perfect_paper"
import topbar from "../vendor/topbar"
import SidebarDrawer from "./hooks/sidebar_drawer"
import PaneResize from "./hooks/pane_resize"
import FitText from "./hooks/fit_text"
import initHeroDemo from "./hero_demo"
import initLegalPages from "./legal_toc"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, SidebarDrawer, PaneResize, FitText},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// CSP-safe clipboard copy — dispatched by phx-click={JS.dispatch("phx:copy", detail: %{text: ...})}
window.addEventListener("phx:copy", (e) => {
  const text = e.detail && e.detail.text
  if (!text) return
  navigator.clipboard.writeText(text).catch(() => {
    // Fallback: select a nearby readonly input if clipboard API is unavailable
    const input = e.target && e.target.closest("[data-copy-target]")
    if (input) { input.select(); document.execCommand("copy") }
  })
})

// Low-credit banner dismiss — persists a per-session cookie so the stateless
// banner stays hidden across navigations until the balance recovers.
window.addEventListener("phx:dismiss-low-credit", () => {
  const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
  fetch("/credit-banner/dismiss", {
    method: "POST",
    headers: { "x-csrf-token": csrf },
    credentials: "same-origin"
  })
})

// Plain-DOM modules for the server-rendered (dead-view) marketing pages: the
// animated hero demo on the home page, and scroll-spy + back-to-top on the
// legal/policy pages. These run on every page; each is a no-op when its target
// markup is absent.
function initStaticPages() {
  initHeroDemo()
  initLegalPages()
}

if (document.readyState !== "loading") {
  initStaticPages()
} else {
  window.addEventListener("DOMContentLoaded", initStaticPages)
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

