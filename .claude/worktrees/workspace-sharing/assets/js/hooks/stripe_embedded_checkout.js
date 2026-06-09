// Mounts Stripe's Embedded Checkout in-app from a server-provided client_secret.
// The wrapper element is phx-update="ignore" and keyed by a per-session nonce id,
// so a new client_secret yields a new id → the hook remounts cleanly.

let stripeJsPromise = null

function loadStripeJs() {
  if (stripeJsPromise) return stripeJsPromise
  stripeJsPromise = new Promise((resolve, reject) => {
    if (window.Stripe) return resolve(window.Stripe)
    const script = document.createElement("script")
    // Latest Stripe.js channel (matches the 2026-05-27.dahlia API version).
    script.src = "https://js.stripe.com/dahlia/stripe.js"
    script.async = true
    script.onload = () => resolve(window.Stripe)
    script.onerror = () => reject(new Error("stripe_js_load_failed"))
    document.head.appendChild(script)
  })
  return stripeJsPromise
}

const StripeEmbeddedCheckout = {
  async mounted() {
    const clientSecret = this.el.dataset.clientSecret
    const publishableKey = this.el.dataset.publishableKey

    try {
      const Stripe = await loadStripeJs()
      if (!Stripe || !publishableKey || !clientSecret) {
        this.pushEvent("checkout_client_error", {stage: "init"})
        return
      }

      const stripe = Stripe(publishableKey)
      this.checkout = await stripe.initEmbeddedCheckout({clientSecret})
      this.checkout.mount(this.el)
    } catch (_e) {
      this.pushEvent("checkout_client_error", {stage: "mount"})
    }
  },

  destroyed() {
    if (this.checkout) {
      try {
        this.checkout.destroy()
      } catch (_e) {
        // ignore — already torn down
      }
    }
  },
}

export default StripeEmbeddedCheckout
