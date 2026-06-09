defmodule PerfectPaper.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias PerfectPaper.Repo

  alias PerfectPaper.Accounts.{User, UserToken, UserNotifier, UserIdentity, OAuth}
  alias PerfectPaper.Organizations

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_user!(Ecto.UUID.t()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Gets a single user by id, or `nil` if none exists."
  @spec get_user(Ecto.UUID.t()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Returns the user's locale, defaulting to `\"en\"` when the user is missing or
  has no locale set. Used by other contexts to localize output for a user.
  """
  @spec get_user_locale(Ecto.UUID.t()) :: String.t()
  def get_user_locale(id) do
    case Repo.get(User, id) do
      %User{locale: locale} when is_binary(locale) -> locale
      _ -> "en"
    end
  end

  ## User registration

  # The academic/government email allowlist — the one place to tune which domains
  # qualify for the free signup credit. `@academic_tlds` match the final label
  # (US-style: harvard.edu, nasa.gov); `@academic_slds` match the second-to-last
  # label of a country-coded domain (international: ox.ac.uk, anu.edu.au,
  # gov.uk, gob.mx).
  @academic_tlds ~w(edu gov mil)
  @academic_slds ~w(edu ac gov gob govt)

  @doc """
  Whether `email`'s domain is an academic or government address (US or common
  international equivalents) — the gate for the free signup credit.

      iex> academic_email?("a@stanford.edu"); true
      iex> academic_email?("b@ox.ac.uk");     true
      iex> academic_email?("c@gmail.com");     false
  """
  @spec academic_email?(String.t() | nil) :: boolean()
  def academic_email?(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() |> String.split("@") do
      [_local, domain] when domain != "" -> academic_domain?(domain)
      _ -> false
    end
  end

  def academic_email?(_), do: false

  defp academic_domain?(domain) do
    case domain |> String.split(".") |> Enum.reverse() do
      [tld | _] when tld in @academic_tlds -> true
      [_cc, sld | _] when sld in @academic_slds -> true
      _ -> false
    end
  end

  @doc """
  Registers a user (self-initiated magic-link sign-up).

  Persists the user record and dispatches the `:signup` credit campaign so the
  new writer receives their signup bonus.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    email = attrs[:email] || attrs["email"]

    case email && get_user_by_email(email) do
      %User{} = existing ->
        if guest?(existing),
          do: promote_guest(existing, :sso),
          else: normal_register_user(attrs)

      _ ->
        normal_register_user(attrs)
    end
  end

  defp normal_register_user(attrs) do
    with {:ok, user} <- insert_user_record(attrs),
         {:ok, user} <- Repo.update(User.promote_changeset(user)) do
      PerfectPaper.Credits.dispatch(:signup, %{user_id: user.id, email: user.email})
      {:ok, user}
    end
  end

  @doc """
  Finds an existing user by email, or creates a new passwordless (magic-link)
  guest account for that address. Returns `{:ok, user}`. A guest is a full
  `User` row with no org membership — the caller is responsible for granting
  access to whichever resource prompted the invitation.

  Guests do **not** receive the signup credit. They are invited collaborators,
  not self-initiated sign-ups, so issuing the credit would be a credit-harvesting
  / sybil vector.
  """
  @spec find_or_create_guest(String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_guest(email) when is_binary(email) do
    case get_user_by_email(email) do
      %User{} = user -> {:ok, user}
      nil -> insert_user_record(%{email: email})
    end
  end

  @doc """
  Promotes an invited guest to a full member via SSO (no password required).

  Confirms the account and, if the user has not already received a signup
  credit, dispatches the `:signup` domain event so the campaign runner issues
  the bonus. Safe to call more than once — repeated calls confirm the account
  again (a no-op when already confirmed) but will NOT issue a second credit.
  """
  @spec promote_guest(User.t(), :sso) :: {:ok, User.t()} | {:error, term()}
  def promote_guest(%User{} = user, :sso),
    do: do_promote(user, sso_promotion_changeset(user))

  @doc """
  Promotes an invited guest to a full member via the password-registration UI.

  Confirms the account, sets and hashes the supplied password, and dispatches
  the `:signup` credit event on first promotion (idempotent). `attrs` must
  include a `:password` key of at least 12 characters.
  """
  @spec promote_guest(User.t(), :password, map()) :: {:ok, User.t()} | {:error, term()}
  def promote_guest(%User{} = user, :password, attrs),
    do: do_promote(user, password_promotion_changeset(user, attrs))

  # Builds a changeset that confirms the user and stamps promoted_at without
  # touching hashed_password. Used for SSO JIT promotion — no password needed.
  @spec sso_promotion_changeset(User.t()) :: Ecto.Changeset.t()
  defp sso_promotion_changeset(%User{} = user) do
    user
    |> User.confirm_changeset()
    |> User.promote_changeset()
  end

  # Builds a changeset that confirms the user, stamps promoted_at, AND sets/hashes
  # the password. Used for password-based registration promotion.
  @spec password_promotion_changeset(User.t(), map()) :: Ecto.Changeset.t()
  defp password_promotion_changeset(%User{} = user, attrs) do
    user
    |> User.confirm_changeset()
    |> User.promote_changeset()
    |> User.password_changeset(attrs)
  end

  # Applies the promotion changeset in a single transaction and dispatches the
  # `:signup` credit event exactly once (guarded by `promoted_at` being nil on
  # the struct passed in — non-nil means this user was already promoted).
  @spec do_promote(User.t(), Ecto.Changeset.t()) :: {:ok, User.t()} | {:error, term()}
  defp do_promote(%User{promoted_at: prior_promoted_at, id: user_id}, changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        if is_nil(prior_promoted_at) do
          PerfectPaper.Credits.dispatch(:signup, %{user_id: user_id, email: user.email})
        end

        {:ok, user}
      end
    end)
  end

  # A "guest" is a user who was created via find_or_create_guest/1 and has never
  # been promoted: no password AND promoted_at is nil AND never confirmed. A
  # magic-link self-signup (register_user/1) also has no password but remains
  # unconfirmed; we distinguish the two by promoted_at alone — guests always have
  # nil promoted_at and nil confirmed_at; register_user users that have gone
  # through login_user_by_magic_link will be confirmed (confirmed_at set). For
  # users where register_user dispatched :signup but magic-link hasn't been
  # clicked yet (unconfirmed, no promoted_at) we also treat as non-guest because
  # the :signup broadcast was already emitted. We use confirmed_at as that proxy:
  # find_or_create_guest always produces unconfirmed users, and register_user
  # paths to guest checking only happen BEFORE the magic-link confirm step.
  # Therefore: hashed_password nil + promoted_at nil + confirmed_at nil = guest.
  @spec guest?(User.t()) :: boolean()
  defp guest?(%User{hashed_password: nil, promoted_at: nil, confirmed_at: nil}), do: true
  defp guest?(%User{}), do: false

  # Inserts the email-only user row WITHOUT dispatching the signup credit campaign.
  # `register_user/1` (self-initiated) wraps this and adds the dispatch;
  # `find_or_create_guest/1` (invited collaborator) calls this directly so guests
  # are never issued an unearned signup bonus.
  @spec insert_user_record(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  defp insert_user_record(attrs), do: %User{} |> User.email_changeset(attrs) |> Repo.insert()

  @doc """
  Registers a user with a password set at sign-up (the "Password" tab on the
  registration page). Email-only magic-link sign-up uses `register_user/1`.

  ## Examples

      iex> register_user_with_password(%{email: "a@b.com", password: "longenoughpw"})
      {:ok, %User{}}

      iex> register_user_with_password(%{email: "a@b.com", password: "short"})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_user_with_password(map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def register_user_with_password(attrs) do
    email = attrs[:email] || attrs["email"]

    case email && get_user_by_email(email) do
      %User{} = existing ->
        if guest?(existing),
          do: promote_guest(existing, :password, attrs),
          else: normal_register_user_with_password(attrs)

      _ ->
        normal_register_user_with_password(attrs)
    end
  end

  defp normal_register_user_with_password(attrs) do
    changeset =
      %User{}
      |> User.email_changeset(attrs)
      |> User.password_changeset(attrs)
      |> User.promote_changeset()

    with {:ok, user} <- Repo.insert(changeset) do
      PerfectPaper.Credits.dispatch(:signup, %{user_id: user.id})
      {:ok, user}
    end
  end

  ## Social sign-in (SSO)

  @display_order ~w(google microsoft orcid github apple)

  @doc "Builds the provider authorize URL (delegates to the OAuth adapter)."
  @spec sso_authorize_url(String.t()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def sso_authorize_url(provider) do
    OAuth.adapter().authorize_url(provider)
  end

  @doc """
  Completes a provider callback and resolves it to a user, applying the linking
  rules (known identity -> auto-link verified -> create -> reject unverified
  collision -> reject missing email).
  """
  @spec sso_sign_in(String.t(), map(), map()) ::
          {:ok, User.t()} | {:error, :email_taken | :email_required | term()}
  def sso_sign_in(provider, params, session_params) do
    with {:ok, identity} <- OAuth.adapter().callback(provider, params, session_params) do
      resolve_sso_identity(identity, trusted_domain: false)
    end
  end

  @doc "Providers that have credentials configured, in display order."
  @spec configured_providers() :: [String.t()]
  def configured_providers do
    configured = Application.get_env(:perfect_paper, :oauth_providers, %{})
    Enum.filter(@display_order, &Map.has_key?(configured, &1))
  end

  @doc """
  Resolves a normalized IdP identity map to a `User`, creating or linking
  records as needed.

  This is the single authoritative identity-resolution function. It is called
  by both generic social OAuth (`sso_sign_in/3`) and enterprise SSO
  (`SSO.sign_in/3`). The `opts[:trusted_domain]` flag (default `false`) enables
  the enterprise-SSO security rules (Rule 1 and Rule 2 below) that are only
  safe when the caller has already verified that the identity email's domain is
  owned by the org.

  ## Resolution order

  1. **Known `UserIdentity`** (provider + uid match) → return the linked user.
  2. **Missing email** → `{:error, :email_required}`.
  3. **Existing user by email:**
     - Verified email AND user already confirmed → link identity → `{:ok, user}`.
     - **Rule 1 — Invited guest** (`trusted_domain: true` OR social OAuth, no
       password, not promoted, not confirmed): link identity + promote the guest
       account → `{:ok, user}`. Safe: no password means no backdoor.
     - **Rule 2 — Squatter with password (trusted domain only):** if
       `trusted_domain: true`, nullify `hashed_password` AND revoke all active
       sessions for that user, then link the identity and confirm the account →
       `{:ok, user}`. Only safe because the caller has proven the org owns the
       email domain. If NOT `trusted_domain`, returns `{:error, :email_taken}`.
  4. **No existing user** → create user + identity (confirmed iff
     `email_verified`).
  """
  @spec resolve_sso_identity(map(), keyword()) ::
          {:ok, User.t()} | {:error, :email_taken | :email_required | term()}
  def resolve_sso_identity(%{provider: provider, uid: uid} = identity, opts \\ []) do
    trusted = Keyword.get(opts, :trusted_domain, false)

    case Repo.get_by(UserIdentity, provider: provider, provider_uid: uid) do
      %UserIdentity{} = link -> {:ok, Repo.get!(User, link.user_id)}
      nil -> link_or_create(identity, trusted)
    end
  end

  defp link_or_create(%{email: nil}, _trusted), do: {:error, :email_required}

  defp link_or_create(%{email: email, email_verified: verified} = identity, trusted) do
    case Repo.get_by(User, email: email) do
      nil ->
        create_user_with_identity(identity)

      %User{} = user ->
        cond do
          # Existing identity link was found upstream; this branch handles
          # email-only matches. Confirmed user with verified email → auto-link.
          verified && user.confirmed_at != nil ->
            link_identity(user, identity)

          # Rule 1: invited guest (no password, never promoted, unconfirmed).
          # Safe regardless of trusted_domain — no password means no backdoor.
          guest?(user) ->
            link_and_promote_guest(user, identity)

          # Rule 2: squatter with password, but org has proven domain ownership.
          # Nullify password + revoke all sessions, then link + confirm.
          trusted && user.hashed_password != nil ->
            neutralize_squatter_and_link(user, identity)

          # Generic OAuth or unverified: cannot override; reject collision.
          true ->
            {:error, :email_taken}
        end
    end
  end

  # Links the identity to the guest user and promotes the account (no password
  # needed — SSO is the credential). Dispatches :signup credit on first promotion.
  @spec link_and_promote_guest(User.t(), map()) :: {:ok, User.t()} | {:error, term()}
  defp link_and_promote_guest(%User{} = user, identity) do
    Repo.transact(fn ->
      with {:ok, _} <- link_identity(user, identity),
           {:ok, promoted_user} <- promote_guest(user, :sso) do
        {:ok, promoted_user}
      end
    end)
  end

  # Enterprise SSO squatter neutralization (Rule 2).
  # Precondition: caller has verified the org owns the email domain.
  # Steps: (a) null out hashed_password + confirm, (b) revoke all tokens,
  # (c) link the IdP identity. This kills the password backdoor and forces any
  # existing sessions off before the new SSO session is established.
  @spec neutralize_squatter_and_link(User.t(), map()) :: {:ok, User.t()} | {:error, term()}
  defp neutralize_squatter_and_link(%User{} = user, identity) do
    Repo.transact(fn ->
      neutralize_changeset =
        user
        |> Ecto.Changeset.change(%{hashed_password: nil})
        |> User.confirm_changeset()

      with {:ok, updated_user} <- Repo.update(neutralize_changeset),
           _count <- Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id)),
           {:ok, _} <- link_identity(updated_user, identity) do
        {:ok, updated_user}
      end
    end)
  end

  defp link_identity(user, identity) do
    case Repo.insert(identity_changeset(user.id, identity)) do
      {:ok, _} -> {:ok, user}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp create_user_with_identity(%{email: email, email_verified: verified} = identity) do
    base = User.email_changeset(%User{}, %{email: email})
    # Only mark confirmed when the provider actually verified the email; an
    # unverified provider email creates an unconfirmed account instead.
    user_changeset = if verified, do: User.confirm_changeset(base), else: base

    multi = create_user_with_identity_multi(user_changeset, identity)

    case Repo.transaction(multi) do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  # `Ecto.Multi.t()` contains opaque subterms (notably `MapSet.t()`), and ElixirLS
  # Dialyzer can incorrectly report opaqueness mismatches when building a fresh
  # Multi via `Ecto.Multi.new()` in a pipeline. This function is a pure builder
  # and the runtime behavior is correct, so we suppress the false positive here.
  ## Directory provisioning / deprovisioning (SCIM)

  @doc "Deactivates a user (directory deprovisioning): stamps deactivated_at and deletes all tokens."
  @spec deactivate_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_user(%User{} = user) do
    Repo.transact(fn ->
      with {:ok, updated} <- Repo.update(User.deactivate_changeset(user)) do
        # Revoke session tokens AND API keys. Without the key revocation a
        # deprovisioned user keeps REST access via a pre-existing API key (the
        # :api auth path has no deactivated_at gate; see Tokens.user_for_bearer).
        Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)
        _ = PerfectPaper.ApiKeys.revoke_all_for_user(user.id)
        {:ok, updated}
      end
    end)
  end

  @doc "Reactivates a previously deactivated user."
  @spec reactivate_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reactivate_user(%User{} = user), do: Repo.update(User.reactivate_changeset(user))

  @doc "Looks up a user by an external identity (provider, uid). Nil if none."
  @spec get_user_by_identity(String.t(), String.t()) :: User.t() | nil
  def get_user_by_identity(provider, uid) do
    case Repo.get_by(UserIdentity, provider: provider, provider_uid: uid) do
      %UserIdentity{user_id: id} -> Repo.get(User, id)
      nil -> nil
    end
  end

  @doc """
  Resolves the user + org behind an Entra AAD object id, by matching it against an
  enterprise SSO identity (`provider` like `oidc:<org_id>`, `provider_uid` = oid).
  Returns `%{user: %User{}, org_id: org_id}` or `nil`. The org id is parsed from the
  provider string so callers (Teams) can tenant-scope the match against SSO config.
  """
  @spec get_oidc_identity_by_oid(String.t()) :: %{user: User.t(), org_id: String.t()} | nil
  def get_oidc_identity_by_oid(aad_object_id) when is_binary(aad_object_id) do
    query =
      from i in UserIdentity,
        where: i.provider_uid == ^aad_object_id and like(i.provider, "oidc:%"),
        limit: 1

    case Repo.one(query) do
      nil ->
        nil

      %UserIdentity{user_id: uid, provider: "oidc:" <> org_id} ->
        %{user: Repo.get!(User, uid), org_id: org_id}

      _ ->
        nil
    end
  end

  @doc """
  Returns the org id of the user's enterprise SSO (`oidc:<org_id>`) identity, or
  `nil` if the user has none. Accounts owns `user_identities`; callers that need
  the org's IdP tenant (Teams) pass this org id to `SSO.get_config_by_org_id/1`,
  keeping the SSO-config data behind the SSO context. If a user somehow has more
  than one enterprise identity, the first by row id is returned.
  """
  @spec get_oidc_org_id_for_user(Ecto.UUID.t()) :: String.t() | nil
  def get_oidc_org_id_for_user(user_id) when is_binary(user_id) do
    query =
      from i in UserIdentity,
        where: i.user_id == ^user_id and like(i.provider, "oidc:%"),
        order_by: [asc: i.id],
        limit: 1,
        select: i.provider

    case Repo.one(query) do
      "oidc:" <> org_id -> org_id
      _ -> nil
    end
  end

  @doc """
  Links an external identity to a user (generic; used by SCIM + SSO). `attrs`
  carries `:provider`, `:provider_uid`, and optionally `:provider_email`.
  """
  @spec create_identity(User.t(), map()) :: {:ok, UserIdentity.t()} | {:error, Ecto.Changeset.t()}
  def create_identity(%User{} = user, attrs) do
    %UserIdentity{}
    |> UserIdentity.changeset(Map.put(attrs, :user_id, user.id))
    |> Repo.insert()
  end

  @doc """
  Finds an existing user by email or provisions a new CONFIRMED, passwordless
  member user. Confirmed (not a guest) so that a later SSO login auto-links by
  email rather than colliding. No org membership is created here — the caller
  (Scim) adds it.
  """
  @spec find_or_provision_member(String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def find_or_provision_member(email) when is_binary(email) do
    case get_user_by_email(email) do
      %User{} = user ->
        {:ok, user}

      nil ->
        %User{}
        |> User.email_changeset(%{email: email})
        |> User.confirm_changeset()
        |> Repo.insert()
    end
  end

  @doc """
  Filters `user_ids` to those that actually exist. SCIM group sync uses this to
  avoid an FK violation when an IdP references a member we have purged locally.
  """
  @spec existing_user_ids([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def existing_user_ids(user_ids) when is_list(user_ids) do
    Repo.all(from u in User, where: u.id in ^user_ids, select: u.id)
  end

  @dialyzer {:nowarn_function, create_user_with_identity_multi: 2}
  defp create_user_with_identity_multi(user_changeset, identity) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, user_changeset)
    |> Ecto.Multi.insert(:identity, fn %{user: user} ->
      identity_changeset(user.id, identity)
    end)
  end

  defp identity_changeset(user_id, %{provider: provider, uid: uid, email: email}) do
    UserIdentity.changeset(%UserIdentity{}, %{
      user_id: user_id,
      provider: provider,
      provider_uid: uid,
      provider_email: email
    })
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  @spec sudo_mode?(User.t(), integer()) :: boolean()
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `PerfectPaper.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_email(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  @spec update_user_email(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           # Changing the login identity is sensitive: revoke ALL of the user's
           # tokens (every session + the change-email token), mirroring password
           # change, so the change logs the user out everywhere.
           {_count, _result} <-
             Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id)) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `PerfectPaper.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_password(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_user_password(User.t(), map()) ::
          {:ok, {User.t(), [UserToken.t()]}} | {:error, Ecto.Changeset.t()}
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  @spec get_user_by_session_token(binary()) :: {User.t(), DateTime.t()} | nil
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  @spec get_user_by_magic_link_token(binary()) :: User.t() | nil
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  @spec login_user_by_magic_link(binary()) ::
          {:ok, {User.t(), [UserToken.t()]}} | {:error, :not_found}
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        result =
          user
          |> User.confirm_changeset()
          |> update_user_and_delete_all_tokens()

        with {:ok, {confirmed_user, _expired}} <- result do
          deliver_welcome(confirmed_user)
        end

        result

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_update_email_instructions(User.t(), String.t(), (String.t() -> String.t())) ::
          {:ok, map()} | {:error, term()}
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  @spec deliver_login_instructions(User.t(), (String.t() -> String.t())) ::
          {:ok, map()} | {:error, term()}
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  @spec delete_user_session_token(binary()) :: :ok
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  # Sends the welcome email after first confirmation. A delivery failure must
  # never roll back the confirmation, so we log and continue.
  defp deliver_welcome(user) do
    case UserNotifier.deliver_welcome(user) do
      {:ok, _email} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to send welcome email to #{user.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  @doc "Returns a changeset for the user's locale preference (for forms)."
  @spec change_user_locale(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_locale(%User{} = user, attrs \\ %{}) do
    User.locale_changeset(user, attrs)
  end

  @doc "Persists the user's locale preference."
  @spec update_user_locale(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_locale(%User{} = user, locale) do
    user |> User.locale_changeset(%{locale: locale}) |> Repo.update()
  end

  @doc "Returns a changeset for editing the user's credit alert threshold."
  @spec change_credit_alert_threshold(User.t(), map()) :: Ecto.Changeset.t()
  def change_credit_alert_threshold(%User{} = user, attrs \\ %{}) do
    User.credit_alert_threshold_changeset(user, attrs)
  end

  @doc """
  Persists the user's credit alert threshold. A `nil` threshold means "use the
  plan default" (5 for annual, 2 for monthly/none); 0 disables the alert.
  """
  @spec update_credit_alert_threshold(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_credit_alert_threshold(%User{} = user, attrs) do
    user |> User.credit_alert_threshold_changeset(attrs) |> Repo.update()
  end

  @doc """
  Persists the user's last-used workspace pointer. The caller (Workspaces)
  authorizes that the user owns `workspace_id`; Accounts owns the `users` write.
  """
  @spec set_active_workspace(User.t(), Ecto.UUID.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_active_workspace(%User{} = user, workspace_id) do
    user |> Ecto.Changeset.change(active_workspace_id: workspace_id) |> Repo.update()
  end

  ## MFA

  @doc """
  Sets the `mfa_enabled` flag on a user.

  Persists the change immediately. Use this to opt a user in or out of MFA.
  """
  @spec set_mfa_enabled(User.t(), boolean()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_mfa_enabled(%User{} = user, enabled) when is_boolean(enabled) do
    user
    |> Ecto.Changeset.change(mfa_enabled: enabled)
    |> Repo.update()
  end

  @doc """
  Returns `true` if MFA is required for the given user.

  MFA is required when either:
  - The user has opted in (their `mfa_enabled` flag is true), or
  - Any organization the user belongs to (or owns) has `mfa_required` set.
  """
  @spec mfa_required_for?(User.t()) :: boolean()
  def mfa_required_for?(%User{} = user) do
    user.mfa_enabled || Organizations.mfa_required_for_user?(user.id)
  end

  @doc """
  Begins an MFA factor enrollment flow for the user.

  ## TODO(mfa): call MFA.begin_enrollment, return the enrollment challenge.
  """
  @spec enroll_mfa_factor(User.t(), atom()) :: {:error, :not_implemented}
  def enroll_mfa_factor(%User{} = _user, _type) do
    # TODO(mfa): call MFA.begin_enrollment, return the enrollment challenge.
    {:error, :not_implemented}
  end

  @doc """
  Confirms an in-progress MFA factor enrollment with the supplied proof.

  ## TODO(mfa): MFA.confirm_enrollment then persist a confirmed Factor + set mfa_enabled.
  """
  @spec confirm_mfa_factor(User.t(), atom(), term()) :: {:error, :not_implemented}
  def confirm_mfa_factor(%User{} = _user, _type, _proof) do
    # TODO(mfa): MFA.confirm_enrollment then persist a confirmed Factor + set mfa_enabled.
    {:error, :not_implemented}
  end

  @doc """
  Verifies a presented MFA proof against the user's confirmed factor.

  ## TODO(mfa): MFA.verify against the user's confirmed factor; touch last_used_at.
  """
  @spec verify_mfa(User.t(), atom(), term()) :: {:error, :not_implemented}
  def verify_mfa(%User{} = _user, _type, _proof) do
    # TODO(mfa): MFA.verify against the user's confirmed factor; touch last_used_at.
    {:error, :not_implemented}
  end

  @doc """
  Regenerates recovery codes for the user's MFA setup.

  ## TODO(mfa): generate N codes, store hashes, return plaintext once.
  """
  @spec regenerate_recovery_codes(User.t()) :: {:error, :not_implemented}
  def regenerate_recovery_codes(%User{} = _user) do
    # TODO(mfa): generate N codes, store hashes, return plaintext once.
    {:error, :not_implemented}
  end
end
