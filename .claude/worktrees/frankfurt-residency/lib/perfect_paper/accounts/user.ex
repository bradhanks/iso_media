defmodule PerfectPaper.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @type id :: Ecto.UUID.t()

  @type t :: %__MODULE__{
          id: id(),
          email: String.t() | nil,
          password: String.t() | nil,
          hashed_password: String.t() | nil,
          confirmed_at: DateTime.t() | nil,
          authenticated_at: DateTime.t() | nil,
          promoted_at: DateTime.t() | nil,
          mfa_enabled: boolean(),
          deactivated_at: DateTime.t() | nil,
          locale: String.t(),
          active_workspace_id: Ecto.UUID.t() | nil,
          credit_alert_threshold: non_neg_integer() | nil,
          identities: [PerfectPaper.Accounts.UserIdentity.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :promoted_at, :utc_datetime
    field :mfa_enabled, :boolean, default: false
    field :deactivated_at, :utc_datetime
    field :locale, :string, default: "en"
    field :active_workspace_id, :binary_id
    field :credit_alert_threshold, :integer

    has_many :identities, PerfectPaper.Accounts.UserIdentity

    timestamps(type: :utc_datetime)
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :locale])
    |> sanitize_locale()
    |> validate_email(opts)
  end

  # An unknown/absent locale at registration falls back to the schema default
  # rather than failing the whole signup.
  defp sanitize_locale(changeset) do
    case get_change(changeset, :locale) do
      nil ->
        changeset

      locale ->
        if PerfectPaper.Localization.known?(locale),
          do: changeset,
          else: delete_change(changeset, :locale)
    end
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, PerfectPaper.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Marks the guest account as promoted by setting `promoted_at` to now.

  This is the idempotency marker for `Accounts.promote_guest/2,3`: a non-nil
  `promoted_at` means the `:signup` credit event was already dispatched and
  must not be re-broadcast on a subsequent promote call.
  """
  def promote_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, promoted_at: now)
  end

  @doc "Marks the user deactivated (directory deprovisioning)."
  @spec deactivate_changeset(t()) :: Ecto.Changeset.t()
  def deactivate_changeset(user) do
    change(user, deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc "Clears the deactivated flag (directory reactivation)."
  @spec reactivate_changeset(t()) :: Ecto.Changeset.t()
  def reactivate_changeset(user) do
    change(user, deactivated_at: nil)
  end

  @doc "Changeset for the user's credit alert threshold setting."
  @spec credit_alert_threshold_changeset(t(), map()) :: Ecto.Changeset.t()
  def credit_alert_threshold_changeset(user, attrs) do
    user
    |> cast(attrs, [:credit_alert_threshold])
    # Bound to the largest pack (12) so the banner can't be set permanently-on;
    # 0 disables the alert (the trigger guards on threshold > 0).
    |> validate_number(:credit_alert_threshold,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 12
    )
  end

  @doc "Changeset for the user's UI/AI language preference."
  @spec locale_changeset(t(), map()) :: Ecto.Changeset.t()
  def locale_changeset(user, attrs) do
    user
    |> cast(attrs, [:locale])
    |> validate_required([:locale])
    |> validate_inclusion(:locale, PerfectPaper.Localization.codes())
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%PerfectPaper.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
