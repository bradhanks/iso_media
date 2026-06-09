# Social sign-in (OAuth) setup

PerfectPaper supports social sign-in via Google and GitHub (more providers in
later phases). The application code is complete — each provider **turns on** once
you register an OAuth app with that provider and set its credentials as
environment variables, then restart the server.

A provider's button appears on the register and login pages **only** when its
env vars are present. With no vars set, no social buttons render and nothing
breaks.

## How it works

- Sign-in starts at `GET /auth/<provider>` and returns to
  `GET /auth/<provider>/callback`.
- **Redirect/callback URI** to register with each provider:
  - Production: `https://<your-host>/auth/<provider>/callback`
  - Local dev: `http://localhost:4000/auth/<provider>/callback`
- New users who sign in with a **verified** provider email are created already
  confirmed. If a provider's email matches an existing account, the identity is
  auto-linked. An unverified provider email that collides with an existing
  account is rejected (the user is told to log in normally and link in Settings).

## Google

1. Go to the Google Cloud Console → **APIs & Services → Credentials**.
2. Configure the **OAuth consent screen** (External), add the scopes
   `openid`, `email`, `profile`.
3. **Create credentials → OAuth client ID → Web application**.
4. Add **Authorized redirect URIs**:
   - `http://localhost:4000/auth/google/callback` (dev)
   - `https://<your-host>/auth/google/callback` (prod)
5. Copy the **Client ID** and **Client secret** into env vars:

```bash
export GOOGLE_CLIENT_ID="…"
export GOOGLE_CLIENT_SECRET="…"
```

## GitHub

1. Go to GitHub → **Settings → Developer settings → OAuth Apps → New OAuth App**.
2. **Authorization callback URL**:
   - `http://localhost:4000/auth/github/callback` (dev) — register a second app
     or update this for prod: `https://<your-host>/auth/github/callback`.
3. Request the `user:email` scope (so we can read the account's primary verified
   email).
4. Copy the **Client ID** and generate a **Client secret**, then set:

```bash
export GITHUB_CLIENT_ID="…"
export GITHUB_CLIENT_SECRET="…"
```

## Apply the changes

After setting the env vars, restart the server:

```bash
mix phx.server
```

The configured providers' buttons will now appear on `/users/register` and
`/users/log-in`. Click one to run the full OAuth flow.

## Later phases

Microsoft (Entra ID), ORCID, and Apple follow the same pattern: register the app,
set the redirect URI to `…/auth/<provider>/callback`, and add the provider's env
vars. Apple's "client secret" is a signed JWT generated from a `.p8` key rather
than a static secret — its setup will be documented when that phase lands.
