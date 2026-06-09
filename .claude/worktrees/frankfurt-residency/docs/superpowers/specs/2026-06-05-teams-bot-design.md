# Microsoft Teams bot — proactive cards + linking + manifest (Spec 5) — Design

**Date:** 2026-06-05
**Status:** Approved (pending written-spec review). The **first slice** of a Teams app: a bot that links a Teams user to their PerfectPaper account, sends proactive Adaptive Cards for events that personally concern them, answers a few read commands, and ships a downloadable Teams app package. Real Bot Framework calls are **stub-only** this pass (behind an adapter). Final item of the 8-spec enterprise roadmap (follows 3a SSO, 3b SCIM, 4 billing). Tab SSO, message extensions, channel notifications, and mutating commands are **deferred sub-specs**.

## Why

Enterprise users live in Microsoft Teams. The highest-value, lowest-risk Teams surface is a bot that proactively tells a user "your review is ready" / "someone commented on your manuscript" in their 1:1 chat, and lets them check status without leaving Teams. It reuses the assets already built: the **`Events`** bus + **Oban** durable delivery (Spec 8), the **behaviour + config-selected adapter** anti-corruption pattern, and — crucially — the **`user_identities`** link from Spec 3a SSO (which already stores each enterprise user's Entra AAD object id), so linking a Teams user to a PerfectPaper account is automatic for the enterprise audience.

## Locked decisions (brainstorming)

| Decision | Choice |
|---|---|
| Surface (this slice) | **Bot + proactive 1:1 cards + downloadable manifest.** Tab SSO / message extensions / channel notifications / mutating commands = later sub-specs. |
| Registration | **Single multi-tenant platform bot** (one Azure Bot registration; app credentials in config behind the adapter). Per-org data is just each user's link + conversation reference. |
| User linking | **AAD object-id match via the Spec 3a `user_identities`** (the `oidc:<org_id>` row stores the AAD oid as `provider_uid`), **tenant-scoped** to the org's verified SSO config. Fallback: a **stateless deep-link token** (no pending-link rows). |
| Inbound behavior | **Link/opt-in on install + read commands** (`status`, `help`, `mute`/`unmute`). No mutating actions from Teams this pass. |
| Notifications | **Per-user 1:1 cards only** for `session.completed`, `comment.added`, `session.shared`. |
| Vendor | **Stub-only** (`Teams.Bot.Stub`, stub `TokenVerifier`); the real Bot Connector + JWKS adapters are `TODO(teams)`. |

## Architecture

### Context boundary — new `Teams` context
The only Teams-aware module and the sole `Repo`/IO boundary for `teams_links`. It validates inbound Activities, links Teams↔PerfectPaper users, renders Adaptive Cards, and sends proactive messages through an adapter. It calls `Accounts`, `History`, and `SSO` via their public APIs only; no Teams/Bot-Framework vocabulary leaks into them.

```
lib/perfect_paper/teams.ex                      # context API + Repo boundary + orchestration
lib/perfect_paper/teams/link.ex                 # teams_links schema + changeset
lib/perfect_paper/teams/activity.ex             # inbound Activity parse/validate (embedded_schema)
lib/perfect_paper/teams/card.ex                 # pure event/command → Adaptive Card JSON
lib/perfect_paper/teams/bot.ex                  # Bot behaviour (send_proactive/2, reply/2)
lib/perfect_paper/teams/bot/stub.ex             # default outbound adapter (records calls)
lib/perfect_paper/teams/token_verifier.ex       # inbound JWT verification behaviour + dispatch
lib/perfect_paper/teams/token_verifier/stub.ex  # test verifier (Process-dict controlled)
lib/perfect_paper/teams/jwks_cache.ex           # GenServer: caches Bot Framework JWKS (24h TTL)
lib/perfect_paper/teams/notifier_server.ex      # Events subscriber → enqueue proactive cards
lib/perfect_paper/teams/notify_worker.ex        # Oban worker (:teams_notifier): render + send
lib/perfect_paper/teams/manifest.ex             # pure manifest.json + ZIP package builder
lib/perfect_paper_web/controllers/teams_controller.ex   # POST /teams/messages, GET /teams/link, manifest download
```

### Data model — `teams_links`
- `id` binary_id; `user_id` binary_id → users **with `on_delete: :delete_all`** (deleting a user cascades their link — never proactively message an orphan record); `aad_object_id` :string (Entra oid); `tenant_id` :string; `service_url` :string; `conversation_reference` :map (the Bot Framework reference used for proactive sends); `muted` :boolean default false; timestamps.
- **Two unique indexes:** `[:user_id]` (a PerfectPaper user has at most one Teams link) AND `[:aad_object_id]` (Entra OIDs are globally unique across all tenants, so this guarantees absolute mapping uniqueness). `conversation_reference` is a plain `:map` (Ecto handles it natively; it is structural Bot Framework data, never business logic).

### Inbound flow — `POST /teams/messages`
1. **Validate the Bot Framework JWT (security core, §Security).** Reject unsigned / wrong-audience / wrong-issuer / serviceUrl-mismatch → 401. Nothing else runs until this passes.
2. Parse the Activity through `Teams.Activity` (embedded_schema validate — "changeset on every write even when it doesn't persist"). Branch on `type`:
   - **`conversationUpdate` (membersAdded = the bot) / first `message`:** extract `from.aadObjectId`, `channelData.tenant.id`, `serviceUrl`, and build the `conversationReference`. **Link:** look up a `user_identities` row whose `provider == "oidc:<org_id>"` and `provider_uid == aadObjectId`, where that org's SSO config is verified for the **same tenant** (`oidc_tenant_id == tenant_id`). Match → upsert `teams_link` + reply a welcome card. No match → reply a **link-code card** (stateless deep link, below).
   - **`message`:** parse a small command set (case-insensitive, first word): `status` → recent sessions for the linked user via `History`; `help` → command list; `mute`/`unmute` → toggle `muted`. Unknown / unlinked → help-or-link card. Reply via `Teams.Bot.reply/2`.

### Stateless link fallback (deep-link token — no pending rows)
When the AAD oid doesn't match (e.g. the user never did SSO), the welcome reply is a **link-code card** with a button to `https://<host>/teams/link?token=<TOKEN>`, where `TOKEN` is a `Phoenix.Token.sign/4` of `%{aad_object_id, tenant_id, conversation_reference, service_url}` with a **15-minute** max age. `GET /teams/link` (normal browser, behind `require_authenticated_user`) verifies the token and **upserts the `teams_link` for the logged-in user** — binding their authenticated PerfectPaper account to the Teams identity carried in the token. No "pending link" table; the signed token IS the state.

### Proactive flow — Events → 1:1 card
`Teams.NotifierServer` (GenServer; mirrors `Credits.AllowanceServer` / `Billing.SeatTrackerServer`) subscribes to `:"session.completed"`, `:"comment.added"`, `:"session.shared"`. On each event it resolves the **affected user** — session owner for `session.completed`; the manuscript (session) owner for `comment.added`, **excluding the comment's own author** (no self-notify); the share recipient for `session.shared` — and **if** that user has a `teams_link` that is **not muted**, enqueues a `Teams.NotifyWorker` Oban job (queue `:teams_notifier`). The worker renders the event via `Teams.Card` (pure Elixir maps → `Jason`, with an explicit `"version": "1.4"` Adaptive Card schema — the version Teams fully supports) and calls `Teams.Bot.send_proactive(conversation_reference, card)`. Durable + retried like webhooks. (Errors logged, never raised, so one bad event can't take the subscriber down.)

> **Rate-limit handling:** the Microsoft Bot Connector returns `429` aggressively. Delivery rides Oban on a dedicated `:teams_notifier` queue set to **low concurrency (5)**, and `NotifyWorker` overrides Oban's `backoff/1` for **exponential backoff with jitter** so retries smooth out under rate limiting. Because this is all queue/worker config, concurrency can be tuned later with zero business-logic change.

### Outbound adapter (stub-only)
`Teams.Bot` behaviour — `send_proactive(conversation_reference, card)` and `reply(activity, card)` — selected by config (`:teams_bot`), default `Teams.Bot.Stub` (records calls for assertions/tests). The real `Teams.Bot.BotConnector` (acquire an app token from the bot app credentials, POST the activity to the `serviceUrl` conversation) is a deferred `TODO(teams)`. Bot app credentials live in app config, referenced only inside the real adapter — never in the `Teams` context.

## Security (first-class — the JWT boundary is to Spec 5 what SAML-signature was to 3a)

- **Inbound JWT validation is THE security boundary.** `POST /teams/messages` is public (machine-to-machine; no session/CSRF), so its ONLY authentication is the Bot Framework bearer token on every Activity. `Teams.TokenVerifier` MUST validate:
  - **signature** against the Bot Framework **JWKS** (`https://login.botframework.com/v1/.well-known/keys`, discovered via the OpenID metadata);
  - **`iss == https://api.botframework.com`**;
  - **`aud == <our registered Microsoft App id>`**;
  - the token's **`serviceUrl` claim exactly equals the activity's `serviceUrl`** (replay/cross-bot defense).
  Any failure → **401**, nothing else runs. Behind a behaviour + stub so tests can drive both the accept and reject paths without network.
- **JWKS caching (mandatory in the real adapter).** Fetching Microsoft's metadata/keys on every request would bottleneck the endpoint and fail on MS downtime / rate limits. `Teams.JwksCache` (GenServer or ETS) caches the keys with a **~24h TTL** and refreshes out of band; the verifier reads from the cache. (The stub verifier bypasses this in tests.)
- **Tenant-scoped linking.** The AAD-oid match is gated to the org's *verified* SSO tenant (`oidc_tenant_id == channelData.tenant.id`), so a user in tenant A cannot bind to a PerfectPaper account whose identity lives in tenant B.
- **`service_url` / `conversation_reference` are trusted only from a JWT-validated activity** (and, for the fallback, only from a `Phoenix.Token` we signed).
- The deep-link `/teams/link` is `require_authenticated_user` — the binding always attaches to the *currently logged-in* PerfectPaper user, never a user named in the token, so a stolen token can't bind to someone else's account. The token is short-lived (15 min), signed, and is only ever delivered to that Teams user's own 1:1 chat with the bot — so possession implies they are that Teams identity.
- **Tenant-consistency check on redeem (defense-in-depth):** when the logged-in user already *has* an SSO `user_identities` row, its `oidc:<org_id>` tenant MUST equal the token's `tenant_id`, else refuse — an SSO user can never bind to a different tenant's Teams identity. (Users with no SSO identity — the fallback's intended audience — are bounded by the signed, short-lived, chat-delivered token above.)

## Manifest — downloadable Teams app package (ZIP)
Teams requires an **app package ZIP**, not bare JSON. `Teams.manifest_package/0` builds, in memory, a ZIP containing `manifest.json` (platform bot id, messaging-endpoint URL, `personal` scope, branding/description), `color.png` (192×192), and `outline.png` (32×32) via Erlang's `:zip.create(..., [:memory])`. An org admin clicks **Download Teams app** and gets a sideload-ready `.zip`. Single platform app → one package (icons are static assets in `priv/`).

> **`:zip` interop:** Erlang's `:zip` expects **charlists** for filenames, not Elixir binaries — use the `~c` sigil (`{~c"manifest.json", json_binary}`, `:zip.create(~c"manifest.zip", files, [:memory])`); passing strings raises `ArgumentError`. File *contents* are binaries.

## Web / UX
- `POST /teams/messages` — public, JWT-gated, on a dedicated `:teams` pipeline (JSON; no browser session/CSRF).
- `GET /teams/link?token=…` — `require_authenticated_user`; verifies the deep-link token and upserts the link, then redirects to settings with a flash.
- `GET /teams/manifest` (or a settings action) — org-admin, returns the ZIP package.
- **Settings panel** (`TeamsLive` or a section on the account page): link status (connected as … / not connected), **unlink**, **mute** toggle; for admins, **Download Teams app**. Discrete test ids, paper theme, no emoji.

## Events
No new event types — consumes existing `session.completed` / `comment.added` / `session.shared`. (An optional `teams.linked` event is deferred.)

## Testing
- **JWT validation (critical):** a valid (stub-accepted) token → Activity processed; unsigned / wrong-`aud` / wrong-`iss` / `serviceUrl`-mismatch → **401**, no link created and no reply sent. Drive both paths through the stub verifier.
- **Linking:** install Activity with an AAD oid that matches a 3a identity (same tenant) → `teams_link` upserted + welcome card; no match → link-code card; **cross-tenant** oid (matches an identity in a different tenant) → refused (link-code fallback, not bound).
- **Deep-link fallback:** a valid `Phoenix.Token` + an authenticated user → `teams_link` bound to *that* user; expired/forged token → rejected; the link attaches to the session user, not a token-named user.
- **Commands:** `status` (linked) → recent sessions card; `help` → command card; `mute` then a `session.completed` for that user → **no** proactive job enqueued; `unmute` restores it.
- **Proactive:** `session.completed` for a linked, unmuted owner → a `NotifyWorker` enqueued and `Bot.Stub` records a `send_proactive`; unlinked or muted → nothing. (`assert_enqueued` / Oban testing.)
- **Card rendering:** each event/command → a well-formed Adaptive Card map (schema + body present).
- **Manifest:** `manifest_package/0` returns a ZIP binary containing `manifest.json` (with the bot id + endpoint) + both icons.
- **Constraints:** the two unique indexes (`user_id`, `aad_object_id`) reject duplicates.

## Out of scope (this pass — TODO / later)
- **Real Bot Connector adapter** + **real JWKS/JWT verifier** (stub only; `TODO(teams)`).
- **Tab SSO** (the existing LiveView in a Teams tab via on-behalf-of token exchange) — the strong next sub-spec.
- Message extensions (compose/search actions).
- **Channel / org-level** notifications (invoice/member events → a team channel) — needs a channel-install reference + admin routing.
- **Mutating commands** (start a review, dismiss/address comments from Teams).
- Microsoft Graph directory calls (covered by SCIM in 3b).

## Definition of done
- `teams_links` migration (+ unique indexes on `user_id` and `aad_object_id`); `Teams.Link` schema/changeset.
- `Teams` context: validate-and-handle inbound Activity (link / command), `link_user`/`unlink`/`set_muted`, deep-link token issue+redeem, proactive dispatch helpers.
- `Teams.TokenVerifier` (behaviour + stub) with the four claim checks; `Teams.JwksCache` (real-adapter caching, `TODO(teams)` for the live fetch); `Teams.Bot` behaviour + `Stub`.
- `Teams.Card` (event/command → Adaptive Card); `Teams.Activity` (inbound parse/validate).
- `Teams.NotifierServer` (Events subscriber, supervised) + `Teams.NotifyWorker` (Oban `:teams_notifier` queue, added to config).
- `Teams.manifest_package/0` (ZIP via `:zip`) + static icons in `priv/`.
- Web: `POST /teams/messages` (JWT-gated `:teams` pipeline), `GET /teams/link`, manifest download; settings Teams panel (status / unlink / mute / download).
- Tests green (JWT accept+reject, tenant-scoped link, deep-link fallback, commands, mute, proactive enqueue+stub, manifest ZIP); `mix precommit` green.

## Open questions
1. **Icons.** Ship two simple PerfectPaper-branded PNG icons (`color.png` 192×192, `outline.png` 32×32) in `priv/static/teams/` this pass — placeholder brand marks are fine; final art is a polish follow-up. (Default: yes, ship placeholders so the ZIP is valid.)
2. **`status` depth.** `status` returns the user's N most recent sessions (title + state). Default N = 5. Confirm during planning.
3. **Settings surface.** A dedicated `TeamsLive` page vs a panel on the existing account page. Default: a panel on the account/settings LiveView (consistent with how SSO/SCIM/billing admin attach), promoted to its own page only if it grows.
