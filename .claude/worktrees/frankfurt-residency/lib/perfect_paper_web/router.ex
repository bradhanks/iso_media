defmodule PerfectPaperWeb.Router do
  use PerfectPaperWeb, :router

  import PerfectPaperWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PerfectPaperWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug PerfectPaperWeb.Plugs.UnicodeSanitizer
    plug PerfectPaperWeb.Plugs.FetchCookieConsent
    plug PerfectPaperWeb.Plugs.FetchLocale
    plug PerfectPaperWeb.Plugs.FetchPricingCountry
    plug PerfectPaperWeb.Plugs.FetchLowCreditDismiss
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug PerfectPaperWeb.Plugs.ApiAuth
    plug PerfectPaperWeb.Plugs.UnicodeSanitizer
  end

  # SCIM 2.0 — authenticated ONLY by the per-org SCIM bearer token (not the
  # regular API key). Accepts both application/json and application/scim+json.
  pipeline :scim do
    plug :accepts, ["json", "scim+json"]
    plug PerfectPaperWeb.Plugs.ScimAuth
  end

  # Public pipeline for the Microsoft Teams bot messaging endpoint. No
  # session/CSRF: it is machine-to-machine, authenticated SOLELY by the inbound
  # Bot Framework JWT (validated in TeamsController.messages/2 via TokenVerifier).
  pipeline :teams do
    plug :accepts, ["json"]
  end

  # Public pipeline for the Stripe webhook. No session/CSRF: it is machine-to-
  # machine, authenticated SOLELY by the Stripe signature (verified in
  # Billing.process_stripe_webhook over the cached raw body).
  pipeline :stripe_webhook do
    plug :accepts, ["json"]
  end

  # Public pipeline for the OpenAPI spec — no auth required.
  pipeline :openapi do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PerfectPaperWeb.Api.Spec
  end

  # Browser pipeline WITHOUT CSRF protection, used ONLY for the SAML ACS
  # (Assertion Consumer Service) POST callback. The IdP POSTs the SAMLResponse
  # cross-site from its own login page and cannot carry our per-session CSRF
  # token, so `protect_from_forgery` would reject every legitimate SSO login.
  # This is safe because request integrity for THIS route is guaranteed by the
  # SAML layer itself: the assertion's XML signature is validated against the
  # org's pinned IdP certificate and the `InResponseTo` is matched to a
  # one-time, session-bound AuthnRequest ID (replay defense). All other browser
  # routes keep full CSRF protection.
  pipeline :saml_acs do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PerfectPaperWeb.Layouts, :root}
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug PerfectPaperWeb.Plugs.UnicodeSanitizer
  end

  # Public docs page — HTML, no auth. CSP is extended beyond the default
  # 'self'-only policy to allow the pinned Redoc CDN bundle (cdn.redoc.ly)
  # and the inline Redoc.init() script block. Without these overrides,
  # put_secure_browser_headers would emit default-src 'self' and block both.
  pipeline :docs do
    plug :accepts, ["html"]

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; " <>
          "script-src 'self' 'unsafe-inline' https://cdn.redoc.ly; " <>
          "style-src 'self' 'unsafe-inline'; " <>
          "img-src 'self' data: https:; " <>
          "font-src 'self' data: https:; " <>
          "worker-src blob:; " <>
          "connect-src 'self'"
    }
  end

  scope "/", PerfectPaperWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/examples", PageController, :examples
    get "/contact", PageController, :contact
    get "/terms", PageController, :terms
    get "/privacy", PageController, :privacy
    get "/privacy/subprocessors", PageController, :subprocessors
    get "/dpa", PageController, :dpa
    get "/testimonials", PageController, :testimonials
    get "/enterprise", PageController, :enterprise
    get "/enterprise/security", PageController, :enterprise_security

    # Referral landing: stash ?ref=<code> in the session, then send to sign-up.
    get "/join", ReferralController, :join

    # Cookie consent — preferences page + the decision endpoint the banner posts to.
    get "/cookie-settings", CookieConsentController, :show
    post "/cookie-consent", CookieConsentController, :update

    # Low-credit banner — per-session dismiss.
    post "/credit-banner/dismiss", CreditBannerController, :dismiss

    # Locale selection — records language choice in a cookie and, when logged in, persists it.
    post "/locale", LocaleController, :update

    # Public, static-data demos of the app (no auth, no DB).
    live_session :public,
      on_mount: [
        {PerfectPaperWeb.UserAuth, :mount_current_scope},
        {PerfectPaperWeb.UserAuth, :load_locale}
      ] do
      live "/demo", DemoLive.Hub, :index
      live "/demo/review", DemoLive.Review, :index
      live "/demo/history", DemoLive.History, :index
      live "/demo/billing", DemoLive.Billing, :index
      live "/demo/earn", DemoLive.Earn, :index

      # EU trust surface — self-service DSAR / privacy rights request form.
      live "/privacy/rights", PrivacyLive.Rights, :index
    end
  end

  # Public OpenAPI spec — no auth required.
  scope "/api" do
    pipe_through :openapi

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  # Public API docs page — brand-themed Redoc viewer, no auth required.
  scope "/api", PerfectPaperWeb.Api do
    pipe_through :docs

    get "/docs", DocsController, :index
  end

  # REST API — Bearer auth (API key or session token), FastAPI-style errors.
  scope "/api", PerfectPaperWeb.Api, as: :api do
    pipe_through :api

    get "/history", HistoryController, :index
    get "/history/:id", HistoryController, :show
    delete "/history/:id", HistoryController, :delete
    post "/history/:id/mark-viewed", HistoryController, :mark_viewed
    patch "/history/:id/visibility", HistoryController, :set_visibility
    patch "/history/:session_id/comments/:comment_id/dismiss", HistoryController, :dismiss
    patch "/history/:session_id/comments/:comment_id/address", HistoryController, :address
    post "/history/:id/comments", HistoryController, :add_comment
    post "/history/:id/invitations", HistoryController, :invite

    get "/credit-score", CreditController, :show

    get "/webhooks", WebhookController, :index
    post "/webhooks", WebhookController, :create
    get "/webhooks/:id", WebhookController, :show
    patch "/webhooks/:id", WebhookController, :update
    delete "/webhooks/:id", WebhookController, :delete
    post "/webhooks/:id/rotate-secret", WebhookController, :rotate_secret
    get "/webhooks/:id/deliveries", WebhookController, :deliveries

    get "/orgs/:org_id/sso", SsoController, :show
    put "/orgs/:org_id/sso", SsoController, :configure
    post "/orgs/:org_id/sso/verify-domain", SsoController, :verify_domain
    post "/orgs/:org_id/sso/enable", SsoController, :enable

    # Enterprise billing — org-admin VIEW (gating in-controller via Organizations.admin?).
    get "/orgs/:org_id/billing/contract", BillingController, :show
    get "/orgs/:org_id/billing/invoices", BillingController, :invoices
  end

  # Enterprise billing — platform-admin MANAGE (sales-arranged, internal only).
  scope "/api", PerfectPaperWeb.Api, as: :api_billing_admin do
    pipe_through [:api, PerfectPaperWeb.Plugs.RequirePlatformAdmin]

    put "/orgs/:org_id/billing/contract", BillingController, :configure
    post "/orgs/:org_id/billing/contract/activate", BillingController, :activate
    post "/orgs/:org_id/billing/invoices/:id/mark-paid", BillingController, :mark_paid
    post "/orgs/:org_id/billing/invoices/:id/void", BillingController, :void
  end

  # SCIM 2.0 service provider — per-org bearer token auth; org derived from the
  # token (no org id in the path). Discovery endpoints here; Users/Groups added
  # alongside their controllers.
  scope "/scim/v2", PerfectPaperWeb.Scim do
    pipe_through :scim

    get "/ServiceProviderConfig", DiscoveryController, :service_provider_config
    get "/ResourceTypes", DiscoveryController, :resource_types
    get "/Schemas", DiscoveryController, :schemas

    get "/Users", UserController, :index
    get "/Users/:id", UserController, :show
    post "/Users", UserController, :create
    put "/Users/:id", UserController, :update
    patch "/Users/:id", UserController, :patch
    delete "/Users/:id", UserController, :delete

    get "/Groups", GroupController, :index
    get "/Groups/:id", GroupController, :show
    post "/Groups", GroupController, :create
    put "/Groups/:id", GroupController, :update
    patch "/Groups/:id", GroupController, :patch
    delete "/Groups/:id", GroupController, :delete
  end

  # Microsoft Teams bot — public messaging endpoint (JWT-authenticated in the
  # controller; no session/CSRF).
  scope "/teams", PerfectPaperWeb do
    pipe_through :teams

    post "/messages", TeamsController, :messages
  end

  # Stripe webhook — public endpoint, authenticated solely by the Stripe signature.
  scope "/webhooks", PerfectPaperWeb do
    pipe_through :stripe_webhook

    post "/stripe", StripeWebhookController, :handle
  end

  # Teams deep-link redeem + app-package download — browser, authenticated user.
  scope "/teams", PerfectPaperWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/link", TeamsController, :link
    get "/manifest", TeamsController, :manifest
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:perfect_paper, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PerfectPaperWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", PerfectPaperWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {PerfectPaperWeb.UserAuth, :require_authenticated},
        {PerfectPaperWeb.UserAuth, :load_locale},
        {PerfectPaperWeb.UserAuth, :assign_workspace},
        {PerfectPaperWeb.UserAuth, :assign_credit_alert}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      # Workspace-scoped surfaces (the active workspace is in the URL).
      live "/w/:workspace_id/new", NewLive, :new
      live "/w/:workspace_id/reviews", HistoryLive.Index, :index
      live "/w/:workspace_id/review/:id", ReadingRoomLive, :show

      # Review detail (non-scoped list detail) stays available.
      live "/history/:id", HistoryLive.Show, :show

      # Account-level (global) surfaces.
      live "/account", AccountLive, :show
      live "/billing", BillingLive, :index
      live "/billing/success", BillingSuccessLive, :show
      live "/earn", EarnLive, :show
      live "/webhooks", WebhooksLive, :index
      live "/orgs/:org_id/sso", SsoLive, :edit
      live "/orgs/:org_id/review-settings", OrgReviewSettingsLive, :edit
      live "/orgs/:org_id/scim", ScimLive, :edit
      live "/orgs/:org_id/billing", OrgBillingLive, :index
    end

    post "/users/update-password", UserSessionController, :update_password

    # Bare → workspace-scoped redirects (old bookmarks, post-login landing).
    get "/new", WorkspaceRedirectController, :new
    get "/reviews", WorkspaceRedirectController, :reviews
    get "/history", WorkspaceRedirectController, :reviews

    get "/w/:workspace_id/review/:id/export/:format", ExportController, :show
  end

  scope "/admin", PerfectPaperWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_admin,
      on_mount: [
        {PerfectPaperWeb.UserAuth, :require_authenticated},
        {PerfectPaperWeb.UserAuth, :require_admin},
        {PerfectPaperWeb.UserAuth, :load_locale}
      ] do
      live "/credits", AdminLive.Credits, :index
      live "/billing", AdminLive.Billing, :index
    end
  end

  scope "/", PerfectPaperWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {PerfectPaperWeb.UserAuth, :mount_current_scope},
        {PerfectPaperWeb.UserAuth, :load_locale}
      ] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete

    get "/auth/:provider", OAuthController, :request
    get "/auth/:provider/callback", OAuthController, :callback

    # Enterprise SSO — per-org redirect flow. Routes are public (user is not yet
    # authenticated). The OIDC callback is GET with code+state in the query string
    # (the SAML POST callback is wired separately below on the :saml_acs pipeline).
    get "/sso/:org_id/start", SsoController, :request
    get "/sso/:org_id/callback", SsoController, :callback
  end

  # SAML ACS POST callback — separate scope on the CSRF-exempt :saml_acs
  # pipeline (see the pipeline comment). The IdP HTTP-POSTs the SAMLResponse
  # here; integrity is enforced by signature + InResponseTo, NOT CSRF.
  scope "/", PerfectPaperWeb do
    pipe_through :saml_acs

    post "/sso/:org_id/callback", SsoController, :callback
  end
end
