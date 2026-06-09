# MFA + SOC 2 Readiness Scaffold — Implementation Plan (Spec 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Scaffold MFA (TOTP + WebAuthn behind a behaviour) with REAL minimal tables/schemas but STUBBED adapters/flows, place greppable `TODO(mfa):` enforcement markers at the real choke points, and write the SOC 2 Type II readiness docs with a control→code map.

**Architecture:** MFA follows the repo's anti-corruption-layer pattern (behaviour + config-selected adapter), mirroring `Billing.Provider`/`Billing.StubAdapter` and `Chatbot.LLM`/`Chatbot.LLM.Stub`. Real data model (so it's not a retrofit); stub adapters return `{:error, :not_implemented}`. SOC 2 docs leverage the Spec 1 `Authz` choke point + `authz_decisions` log as existing CC6/CC7 evidence.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto/Postgres (binary_id), ExUnit. NO new deps this pass (TOTP/WebAuthn libs named in TODOs only).

**Spec:** `docs/superpowers/specs/2026-06-02-security-mfa-soc2-design.md`

---

## Conventions
- **Stub marker:** every not-yet-implemented body carries a `# TODO(mfa): <what + which lib/ceremony>` comment and returns `{:error, :not_implemented}`. All MFA TODOs use the literal tag `TODO(mfa):` so `grep -rn "TODO(mfa)" lib/` lists the whole backlog.
- **Adapter pattern reference:** read `lib/perfect_paper/billing.ex` + `lib/perfect_paper/billing/stub_adapter.ex` and `lib/perfect_paper/chatbot/llm.ex` (+ `.../llm/stub.ex`) before writing the MFA behaviour — match their `@callback`/config-selection style.
- Architecture laws: `Accounts` is the only public API + Repo boundary for MFA; schemas carry their own changesets; `@spec`/`@type`/`@moduledoc` throughout; org policy writes go through `Organizations` and are `Authz.permit?`-gated.

## File structure
**Create:**
- `priv/repo/migrations/20260602110000_create_mfa.exs` — factors + recovery codes tables + the two boolean columns.
- `lib/perfect_paper/accounts/mfa.ex` — behaviour (`@callback`s) + dispatcher.
- `lib/perfect_paper/accounts/mfa/totp.ex`, `.../mfa/web_authn.ex` — stub adapters.
- `lib/perfect_paper/accounts/mfa/factor.ex`, `.../mfa/recovery_code.ex` — schemas + changesets.
- `test/perfect_paper/accounts/mfa_test.exs`, `.../mfa/factor_test.exs`, `.../mfa/recovery_code_test.exs`.
- `test/support/fixtures/mfa_fixtures.ex`.
- `docs/compliance/soc2/{README,readiness,controls,evidence,gaps}.md`.

**Modify:**
- `lib/perfect_paper/accounts.ex` — context stub functions + `mfa_required_for?/1`.
- `lib/perfect_paper/accounts/user.ex` — `mfa_enabled` field + changeset path.
- `lib/perfect_paper/organizations.ex` + `.../organizations/organization.ex` — `mfa_required` field + `set_mfa_required/2`.
- `config/config.exs` (+ `test.exs`) — `:mfa_provider` (or per-type adapter) config.
- `lib/perfect_paper_web/user_auth.ex` — `TODO(mfa)` at login + a `:require_mfa` `on_mount` stub.
- the API token path (`lib/perfect_paper_web/.../tokens.ex` / `plugs/api_auth.ex` — locate exact) — `TODO(mfa)` marker.

---

## Task 1: MFA data model (migrations + schemas + changesets)

**Files:** migration `priv/repo/migrations/20260602110000_create_mfa.exs`; `lib/perfect_paper/accounts/mfa/factor.ex`; `lib/perfect_paper/accounts/mfa/recovery_code.ex`; modify `user.ex` + `organization.ex`; tests `factor_test.exs`, `recovery_code_test.exs`.

- [ ] **Step 1 — migration.** Create `priv/repo/migrations/20260602110000_create_mfa.exs`:

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateMfa do
  use Ecto.Migration

  def change do
    create table(:user_mfa_factors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :secret, :binary
      add :label, :string
      add :confirmed_at, :utc_datetime
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_mfa_factors, [:user_id, :type, :label])
    create index(:user_mfa_factors, [:user_id])

    create table(:mfa_recovery_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :code_hash, :string, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:mfa_recovery_codes, [:user_id])

    alter table(:users) do
      add :mfa_enabled, :boolean, null: false, default: false
    end

    alter table(:organizations) do
      add :mfa_required, :boolean, null: false, default: false
    end
  end
end
```

- [ ] **Step 2 — failing tests.** `test/perfect_paper/accounts/mfa/factor_test.exs`:

```elixir
defmodule PerfectPaper.Accounts.MFA.FactorTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Accounts.MFA.Factor

  test "create_changeset requires user_id and type" do
    cs = Factor.create_changeset(%Factor{}, %{})
    refute cs.valid?
    errors = errors_on(cs)
    assert Map.has_key?(errors, :user_id)
    assert Map.has_key?(errors, :type)
  end

  test "accepts a valid totp factor" do
    cs = Factor.create_changeset(%Factor{}, %{user_id: Ecto.UUID.generate(), type: :totp, label: "phone"})
    assert cs.valid?
  end

  test "rejects an unknown factor type" do
    cs = Factor.create_changeset(%Factor{}, %{user_id: Ecto.UUID.generate(), type: :sms})
    refute cs.valid?
  end
end
```

`test/perfect_paper/accounts/mfa/recovery_code_test.exs`:

```elixir
defmodule PerfectPaper.Accounts.MFA.RecoveryCodeTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Accounts.MFA.RecoveryCode

  test "create_changeset requires user_id and code_hash" do
    cs = RecoveryCode.create_changeset(%RecoveryCode{}, %{})
    refute cs.valid?
    assert %{user_id: _, code_hash: _} = errors_on(cs)
  end

  test "accepts a valid recovery code" do
    cs = RecoveryCode.create_changeset(%RecoveryCode{}, %{user_id: Ecto.UUID.generate(), code_hash: "x"})
    assert cs.valid?
  end
end
```

- [ ] **Step 3 — run, expect FAIL:** `mix test test/perfect_paper/accounts/mfa/factor_test.exs test/perfect_paper/accounts/mfa/recovery_code_test.exs`

- [ ] **Step 4 — schemas.** `lib/perfect_paper/accounts/mfa/factor.ex`:

```elixir
defmodule PerfectPaper.Accounts.MFA.Factor do
  @moduledoc "An enrolled MFA factor (TOTP or WebAuthn). Adapter-owned `secret` is opaque to the context."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_mfa_factors" do
    field :user_id, :binary_id
    field :type, Ecto.Enum, values: [:totp, :webauthn]
    field :secret, :binary
    field :label, :string
    field :confirmed_at, :utc_datetime
    field :last_used_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for enrolling a factor. `secret` must be encrypted before this — TODO(mfa): app-level encryption (SOC 2 CC6.7)."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(factor, attrs) do
    factor
    |> cast(attrs, [:user_id, :type, :secret, :label, :confirmed_at, :last_used_at])
    |> validate_required([:user_id, :type])
    |> unique_constraint([:user_id, :type, :label])
  end
end
```

`lib/perfect_paper/accounts/mfa/recovery_code.ex`:

```elixir
defmodule PerfectPaper.Accounts.MFA.RecoveryCode do
  @moduledoc "A single-use MFA recovery code. Only the hash is stored — TODO(mfa): hashing on generation (SOC 2 CC6.1)."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "mfa_recovery_codes" do
    field :user_id, :binary_id
    field :code_hash, :string
    field :used_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a recovery code (stores hash only)."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(code, attrs) do
    code
    |> cast(attrs, [:user_id, :code_hash, :used_at])
    |> validate_required([:user_id, :code_hash])
  end
end
```

- [ ] **Step 5 — add `mfa_enabled` to User and `mfa_required` to Organization.** In `lib/perfect_paper/accounts/user.ex` add `field :mfa_enabled, :boolean, default: false` to the schema (do NOT add it to the public registration/email/password changesets — it is set only by MFA flows; if there is a settings changeset, leave MFA out of it for now). In `lib/perfect_paper/organizations/organization.ex` add `field :mfa_required, :boolean, default: false` to the schema and include `:mfa_required` in `create_changeset`'s cast list (so orgs can be created with it) — keep existing validations.

- [ ] **Step 6 — run, expect PASS:** the two test files (4 tests). Migrate dev+test DBs if needed.

- [ ] **Step 7 — commit:**
```bash
git add priv/repo/migrations/20260602110000_create_mfa.exs lib/perfect_paper/accounts/mfa/factor.ex lib/perfect_paper/accounts/mfa/recovery_code.ex lib/perfect_paper/accounts/user.ex lib/perfect_paper/organizations/organization.ex test/perfect_paper/accounts/mfa/
git commit -m "feat(mfa): factor + recovery_code tables/schemas; mfa_enabled/mfa_required columns"
```

---

## Task 2: `Accounts.MFA` behaviour + stub adapters + config

**Files:** `lib/perfect_paper/accounts/mfa.ex`, `.../mfa/totp.ex`, `.../mfa/web_authn.ex`; `config/config.exs` + `config/test.exs`; test `test/perfect_paper/accounts/mfa_test.exs`.

- [ ] **Step 1 — read the reference adapters.** Read `lib/perfect_paper/chatbot/llm.ex` + `lib/perfect_paper/chatbot/llm/stub.ex` (or `billing.ex` + `billing/stub_adapter.ex`) to match the `@callback` + `@behaviour` + config-selection idiom exactly.

- [ ] **Step 2 — failing test.** `test/perfect_paper/accounts/mfa_test.exs`:

```elixir
defmodule PerfectPaper.Accounts.MFATest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Accounts.MFA

  test "begin_enrollment is stubbed (not implemented yet) for both types" do
    assert MFA.begin_enrollment(%{id: Ecto.UUID.generate()}, :totp) == {:error, :not_implemented}
    assert MFA.begin_enrollment(%{id: Ecto.UUID.generate()}, :webauthn) == {:error, :not_implemented}
  end

  test "verify is stubbed" do
    assert MFA.verify(%{id: Ecto.UUID.generate()}, :totp, "000000") == {:error, :not_implemented}
  end
end
```

- [ ] **Step 3 — run, expect FAIL.**

- [ ] **Step 4 — behaviour + dispatcher** `lib/perfect_paper/accounts/mfa.ex`:

```elixir
defmodule PerfectPaper.Accounts.MFA do
  @moduledoc """
  The MFA seam: a behaviour with config-selected adapters per factor type
  (TOTP, WebAuthn), following the repo's anti-corruption-layer pattern. Adapters
  return atom-keyed maps matching `Factor` fields. SCAFFOLD: adapters are stubs
  returning `{:error, :not_implemented}` — see `TODO(mfa)` markers.
  """
  alias PerfectPaper.Accounts.MFA

  @type user :: %{id: Ecto.UUID.t()}
  @type factor_type :: :totp | :webauthn

  @callback begin_enrollment(user(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback confirm_enrollment(user(), term()) :: {:ok, map()} | {:error, term()}
  @callback begin_verification(user()) :: {:ok, map()} | {:error, term()}
  @callback verify(user(), term()) :: :ok | {:error, term()}

  @doc "Dispatches to the configured adapter for `type`."
  @spec begin_enrollment(user(), factor_type()) :: {:ok, map()} | {:error, term()}
  def begin_enrollment(user, type), do: adapter(type).begin_enrollment(user, [])

  @spec confirm_enrollment(user(), factor_type(), term()) :: {:ok, map()} | {:error, term()}
  def confirm_enrollment(user, type, proof), do: adapter(type).confirm_enrollment(user, proof)

  @spec begin_verification(user(), factor_type()) :: {:ok, map()} | {:error, term()}
  def begin_verification(user, type), do: adapter(type).begin_verification(user)

  @spec verify(user(), factor_type(), term()) :: :ok | {:error, term()}
  def verify(user, type, proof), do: adapter(type).verify(user, proof)

  defp adapter(:totp), do: config(:totp, MFA.TOTP)
  defp adapter(:webauthn), do: config(:webauthn, MFA.WebAuthn)

  defp config(type, default),
    do: Application.get_env(:perfect_paper, :mfa_adapters, [])[type] || default
end
```

- [ ] **Step 5 — stub adapters.** `lib/perfect_paper/accounts/mfa/totp.ex`:

```elixir
defmodule PerfectPaper.Accounts.MFA.TOTP do
  @moduledoc "TOTP authenticator-app adapter. STUB — TODO(mfa): implement with `nimble_totp` (secret gen, otpauth URI for QR, code verification)."
  @behaviour PerfectPaper.Accounts.MFA

  @impl true
  def begin_enrollment(_user, _opts), do: {:error, :not_implemented}
  # TODO(mfa): generate a TOTP secret + otpauth:// URI for the QR code (nimble_totp).
  @impl true
  def confirm_enrollment(_user, _proof), do: {:error, :not_implemented}
  # TODO(mfa): verify the first 6-digit code against the pending secret, then persist a confirmed Factor.
  @impl true
  def begin_verification(_user), do: {:error, :not_implemented}
  # TODO(mfa): TOTP needs no server challenge — return :ok-shaped no-op once implemented.
  @impl true
  def verify(_user, _proof), do: {:error, :not_implemented}
  # TODO(mfa): NimbleTOTP.valid?(secret, code) against the user's confirmed factor.
end
```

`lib/perfect_paper/accounts/mfa/web_authn.ex` (same shape, moduledoc/TODOs referencing WebAuthn registration/assertion ceremonies + a WebAuthn lib + storing credential id/public key in `Factor.secret`).

- [ ] **Step 6 — config.** In `config/config.exs` add a documented default (optional, since the dispatcher defaults to the stub modules):
```elixir
# MFA adapters per factor type (anti-corruption layer). Stubs until implemented — see Spec 6.
config :perfect_paper, :mfa_adapters,
  totp: PerfectPaper.Accounts.MFA.TOTP,
  webauthn: PerfectPaper.Accounts.MFA.WebAuthn
```
(No test-env override needed — the stubs are the desired test behavior.)

- [ ] **Step 7 — run, expect PASS; commit:**
```bash
git add lib/perfect_paper/accounts/mfa.ex lib/perfect_paper/accounts/mfa/totp.ex lib/perfect_paper/accounts/mfa/web_authn.ex config/config.exs test/perfect_paper/accounts/mfa_test.exs
git commit -m "feat(mfa): Accounts.MFA behaviour + TOTP/WebAuthn stub adapters + config seam"
```

---

## Task 3: `Accounts` context — MFA stubs + `mfa_required_for?/1` (real)

**Files:** modify `lib/perfect_paper/accounts.ex`; `test/support/fixtures/mfa_fixtures.ex`; tests in `test/perfect_paper/accounts_test.exs` (append).

- [ ] **Step 1 — fixtures.** `test/support/fixtures/mfa_fixtures.ex`: `factor_fixture(user, type \\ :totp, attrs \\ %{})` inserting a confirmed `Factor` via `Repo` (fixtures may touch schemas directly). Include a helper to mark a user `mfa_enabled`.

- [ ] **Step 2 — failing tests** (append to `test/perfect_paper/accounts_test.exs`): cover ONLY the real logic, `mfa_required_for?/1`:
```elixir
  describe "mfa_required_for?/1" do
    import PerfectPaper.AccountsFixtures
    import PerfectPaper.OrganizationsFixtures

    test "false for a plain user with no factors and no org policy" do
      refute PerfectPaper.Accounts.mfa_required_for?(user_fixture())
    end

    test "true when the user opted in (mfa_enabled)" do
      user = user_fixture()
      {:ok, user} = PerfectPaper.Accounts.set_mfa_enabled(user, true)
      assert PerfectPaper.Accounts.mfa_required_for?(user)
    end

    test "true when one of the user's orgs requires MFA" do
      user = user_fixture()
      org = organization_fixture(user, %{mfa_required: true})
      membership_fixture(org, user, :member)
      assert PerfectPaper.Accounts.mfa_required_for?(user)
    end
  end
```

- [ ] **Step 3 — run, expect FAIL.**

- [ ] **Step 4 — implement in `lib/perfect_paper/accounts.ex`.** Add:
  - `set_mfa_enabled(user, bool)` — real: updates `users.mfa_enabled` via a focused changeset (`Ecto.Changeset.change(user, mfa_enabled: bool) |> Repo.update()`), with `@spec`/`@doc`.
  - `mfa_required_for?(user)` — real: `user.mfa_enabled || org_requires_mfa?(user.id)`, where `org_requires_mfa?/1` queries memberships→organizations for any `mfa_required` org the user belongs to (inline query through the Organizations data — OR, to respect context boundaries, add `Organizations.mfa_required_for_user?(user_id)` and call it). PREFER adding `Organizations.mfa_required_for_user?/1` and calling it from Accounts, to keep org-table access inside Organizations.
  - STUB context functions (each `# TODO(mfa)` body returning `{:error, :not_implemented}`, with proper `@spec`/`@doc`): `enroll_mfa_factor(user, type)`, `confirm_mfa_factor(user, type, proof)`, `verify_mfa(user, type, proof)`, `regenerate_recovery_codes(user)`. These delegate to `Accounts.MFA` (also stubbed) and/or persist factors — leave the persistence as `TODO(mfa)` for now, just returning `{:error, :not_implemented}`.

- [ ] **Step 5 — add `Organizations.mfa_required_for_user?/1`** in `lib/perfect_paper/organizations.ex` (inline query: any org the user is a member of OR owns with `mfa_required = true`). `@spec`/`@doc`. Add a small Organizations test for it.

- [ ] **Step 6 — run, expect PASS; commit:**
```bash
git add lib/perfect_paper/accounts.ex lib/perfect_paper/organizations.ex test/support/fixtures/mfa_fixtures.ex test/perfect_paper/accounts_test.exs test/perfect_paper/organizations_test.exs
git commit -m "feat(mfa): Accounts MFA stubs + real mfa_required_for?/1 (user opt-in or org policy)"
```

---

## Task 4: Org MFA policy toggle (Authz-gated)

**Files:** modify `lib/perfect_paper/organizations.ex`; test `test/perfect_paper/organizations_test.exs`.

- [ ] **Step 1 — failing test:** `set_mfa_required(org, scope, bool)` requires `:manage_members` (admin) — a viewer/non-admin gets `{:error, :unauthorized}`; an admin/owner succeeds and flips the flag.

```elixir
  describe "set_mfa_required/3" do
    import PerfectPaper.AccountsFixtures
    import PerfectPaper.OrganizationsFixtures

    test "an org admin can require MFA" do
      owner = user_fixture()
      org = organization_fixture(owner)
      {:ok, grp} = PerfectPaper.Organizations.create_group(org, %{name: "Root"})
      group_membership_fixture(grp, owner, :admin)
      scope = PerfectPaper.Authz.load_subject(owner)
      assert {:ok, org} = PerfectPaper.Organizations.set_mfa_required(org, scope, true)
      assert org.mfa_required
    end
  end
```
(If org-level admin authorization isn't expressible via `Authz.permit?` on a group/session resource yet, the simplest Spec-1-consistent check is membership role: confirm the acting user holds `:admin`/`:owner` in the org via a group membership, OR document a `TODO(mfa)` that org-resource authorization arrives with the org-admin surface. Pick the membership-role check if `permit?` has no org-resource clause — and note it.)

- [ ] **Step 2 — run FAIL → implement `set_mfa_required/3`** (gate, then `Organization` changeset update) → run PASS.
- [ ] **Step 3 — commit:** `git commit -m "feat(mfa): Organizations.set_mfa_required/3 (admin-gated org policy)"`

---

## Task 5: Enforcement-point TODO markers (no behavior change)

**Files:** modify `lib/perfect_paper_web/user_auth.ex`; the API token module (`grep -rn "Bearer\|verify_session\|ApiAuth" lib/perfect_paper_web` to locate). No tests (markers only) — but compile must stay clean.

- [ ] **Step 1 — login marker + `:require_mfa` on_mount stub.** In `user_auth.ex`, at the point where a session is established after credential auth, add:
```elixir
  # TODO(mfa): if Accounts.mfa_required_for?(user) and the session is not MFA-verified,
  # redirect to the MFA challenge before establishing the full session. See Spec 6.
```
And add an `on_mount` clause stub:
```elixir
  def on_mount(:require_mfa, _params, _session, socket) do
    # TODO(mfa): halt/redirect an authenticated-but-not-MFA-verified session when
    # Accounts.mfa_required_for?(current_user). No-op until MFA flow ships.
    {:cont, socket}
  end
```
(Place it alongside existing `on_mount` clauses; ensure it compiles and changes nothing yet.)

- [ ] **Step 2 — API token marker.** In the API token issuance/verification module, add a `# TODO(mfa): require a verified factor before issuing/accepting a session bearer token for an MFA-required user.` at the issuance point.

- [ ] **Step 3 — verify + commit.** `mix compile --warnings-as-errors` clean (the new `on_mount` clause must not break existing `on_mount` dispatch). `grep -rn "TODO(mfa)" lib/` should list all markers.
```bash
git add lib/perfect_paper_web/
git commit -m "chore(mfa): TODO(mfa) enforcement markers at login/on_mount/API-token choke points"
```

---

## Task 6: SOC 2 documentation

**Files:** `docs/compliance/soc2/{README,readiness,controls,evidence,gaps}.md`.

- [ ] **Step 1 — write the docs** (no code/tests). Content requirements:
  - `README.md` — what SOC 2 is for this product; Type I vs Type II; that this is a *readiness* artifact; how to use the control map; auditor/period = `TBD`.
  - `readiness.md` — system description (PerfectPaper: manuscripts, AI review, the stack), in-scope Trust Services Criteria (Security/Common Criteria required + Availability + Confidentiality), overall posture summary, and the boundary (what's in/out of the system).
  - `controls.md` — the FULL matrix: every Common Criteria CC1–CC9 (plus selected Availability A1.x and Confidentiality C1.x) as a row: control id | description | implementation/code location | status (Implemented / Partial / Gap / Process) | linked `TODO()` tag. MUST cite real code where it exists: `Authz.permit?/4` + `resource_grants` + role ladder → CC6.1 authorization; `authz_decisions` log → CC6/CC7 audit logging; `UnicodeSanitizer` → input-handling; Git+TDD workflow (CLAUDE.md) → CC8.1 change management; `user_auth.ex` + MFA scaffolding → CC6.1 authentication (Partial, links `TODO(mfa)`).
  - `evidence.md` — per implemented/partial control, the concrete artifact that proves it (e.g. "`authz_decisions` rows", "`permit?/4` + its property tests", "migration history", "this repo's PR/merge discipline").
  - `gaps.md` — consolidated open gaps, each linking to a code `TODO()` tag or a doc-only owner: MFA flow (TODO(mfa)), secret-at-rest encryption (CC6.7), recovery-code hashing (CC6.1), anomaly detection/alerting (CC7), formal availability/backup + confidentiality/data-classification controls, SCIM deprovisioning (→ Spec 3).
- [ ] **Step 2 — commit:** `git add docs/compliance/soc2/ && git commit -m "docs(soc2): Type II readiness + CC1-CC9 control->code map + evidence + gaps"`

---

## Task 7: Pre-merge verification
- [ ] **Step 1:** `mix compile --warnings-as-errors` — clean.
- [ ] **Step 2:** `grep -rn "TODO(mfa)" lib/` — confirm the enforcement + adapter + persistence TODOs are all present and greppable (sanity that the scaffold's backlog is discoverable).
- [ ] **Step 3:** `mix precommit` — fully green (new MFA schema/changeset/`mfa_required_for?`/org-toggle tests pass; stub-adapter test asserts `:not_implemented`). Run `mix format`.
- [ ] **Step 4:** commit any fixups.

---

## Self-review (during authoring)
- **Spec coverage:** behaviour+stub adapters (T2) ✓; real schemas/migrations/columns (T1) ✓; context stubs + `mfa_required_for?` (T3) ✓; org policy toggle, Authz-gated (T4) ✓; enforcement TODOs at the 3 choke points (T5) ✓; SOC 2 docs with control→code map leveraging Spec 1 (T6) ✓; tests for real parts only + stub asserts `:not_implemented` (T1–T4) ✓.
- **Placeholders:** real-part code is complete; stub bodies are intentionally `{:error, :not_implemented}` + `TODO(mfa)` (that IS the deliverable, not a placeholder).
- **No new deps** (TOTP/WebAuthn libs named in TODOs only) — matches the locked decision.
- **Boundary:** org-table access stays in `Organizations` (Accounts calls `Organizations.mfa_required_for_user?/1`); MFA writes go through `Accounts`.
- **Forward note:** org-resource authorization for `set_mfa_required` may use a membership-role check if `permit?` lacks an org-resource clause (T4 documents this) — real org-admin authorization is part of the future org-admin surface.
