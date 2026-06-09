defmodule PerfectPaper.Security.UnicodeSanitizer do
  @moduledoc """
  Detection and sanitization of invisible Unicode instruction injection.

  PerfectPaper feeds user-submitted manuscript text to a language model, which
  makes it a target for two encoding schemes that embed hidden LLM instructions
  in text invisible to human readers but decoded by AI agents:

  - **Zero-Width Binary** — ASCII chars encoded as U+200B (0 bit) and
    U+200C (1 bit), producing 8 invisible chars per ASCII character.
  - **Unicode Tags** — ASCII chars mapped to U+E0000 + codepoint. This block
    was deprecated in Unicode 5.0 but LLM tokenizers still process it.

  This is a pure functional-core leaf (no `Repo`/IO). It backs the request-level
  `PerfectPaperWeb.Plugs.UnicodeSanitizer` and offers `validate_no_hidden_unicode/2`
  as a defense-in-depth changeset validator for high-value text fields.

  ## Usage

      # Detect only
      case UnicodeSanitizer.scan("some user input") do
        {:clean, _}              -> :ok
        {:injection_found, cats} -> handle_injection(cats)
      end

      # Sanitize
      clean_value = UnicodeSanitizer.sanitize(raw_value)

      # Sanitize an entire params map recursively
      clean_params = UnicodeSanitizer.sanitize_params(params)

      # Ecto changeset validator
      changeset
      |> validate_no_hidden_unicode([:title, :content])
  """

  import Ecto.Changeset, only: [get_change: 2, add_error: 3]

  # Zero-width and invisible formatting characters used in the zero-width binary
  # encoding scheme (U+200B/U+200C) and Trojan Source bidi-control attacks.
  # Also covers invisible math operators, BOM, Mongolian vowel separator, and
  # various Hangul filler characters that render with zero width.
  @invisible_pattern ~r/[\x{00AD}\x{034F}\x{115F}\x{1160}\x{180E}\x{200B}-\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{3164}\x{FFA0}\x{FEFF}]/u

  # Unicode Tags block (U+E0000–U+E007F): deprecated "language tags" assigned
  # in Unicode 3.1, removed from active use in 5.0, but still present in the
  # standard and processed by LLM tokenizers. Each tag char encodes one ASCII
  # char as U+E0000 + codepoint.
  @tag_pattern ~r/[\x{E0000}-\x{E007F}]/u

  @typedoc "Attack categories detected in a string"
  @type category :: :zero_width | :unicode_tags

  @typedoc "Path to a nested value in a params map"
  @type param_path :: [String.t() | integer()]

  @doc """
  Scans a string for invisible Unicode injection payloads.

  Returns `{:clean, string}` or `{:injection_found, categories}` where
  `categories` is a list of detected attack scheme atoms.
  """
  @spec scan(String.t()) :: {:clean, String.t()} | {:injection_found, [category()]}
  def scan(string)

  def scan(string) when is_binary(string) do
    categories =
      []
      |> maybe_add(:zero_width, Regex.match?(@invisible_pattern, string))
      |> maybe_add(:unicode_tags, Regex.match?(@tag_pattern, string))

    if categories == [] do
      {:clean, string}
    else
      {:injection_found, categories}
    end
  end

  def scan(value), do: {:clean, value}

  @doc "Returns `true` if the string contains hidden Unicode injection payloads."
  @spec contains_injection?(String.t()) :: boolean()
  def contains_injection?(string)

  def contains_injection?(string) when is_binary(string) do
    Regex.match?(@invisible_pattern, string) or Regex.match?(@tag_pattern, string)
  end

  def contains_injection?(_), do: false

  @doc """
  Strips all invisible Unicode characters from a string, returning plain text
  safe for storage and LLM processing.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(string)

  def sanitize(string) when is_binary(string) do
    string
    |> String.replace(@invisible_pattern, "")
    |> String.replace(@tag_pattern, "")
  end

  def sanitize(value), do: value

  @doc """
  Recursively sanitizes all string values in a params map or list. `Plug.Upload`
  structs and non-string values pass through unchanged.
  """
  @spec sanitize_params(map() | list() | any()) :: map() | list() | any()
  def sanitize_params(params)

  def sanitize_params(%Plug.Upload{} = upload), do: upload

  def sanitize_params(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {k, sanitize_params(v)} end)
  end

  def sanitize_params(params) when is_list(params) do
    Enum.map(params, &sanitize_params/1)
  end

  def sanitize_params(value) when is_binary(value), do: sanitize(value)
  def sanitize_params(value), do: value

  @doc """
  Scans a params map for injection payloads, returning a `{path, categories}`
  tuple for every string value containing hidden Unicode. `path` is the list of
  keys/indices locating the value in the nested structure.
  """
  @spec scan_params(map() | list() | any(), param_path()) :: [{param_path(), [category()]}]
  def scan_params(params, path \\ [])

  def scan_params(%Plug.Upload{}, _path), do: []

  def scan_params(params, path) when is_map(params) do
    Enum.flat_map(params, fn {k, v} -> scan_params(v, path ++ [k]) end)
  end

  def scan_params(params, path) when is_list(params) do
    params
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} -> scan_params(v, path ++ [i]) end)
  end

  def scan_params(value, path) when is_binary(value) do
    case scan(value) do
      {:injection_found, categories} -> [{path, categories}]
      {:clean, _} -> []
    end
  end

  def scan_params(_value, _path), do: []

  @doc """
  Ecto changeset validator that rejects fields containing hidden Unicode. Use
  for high-value text fields (titles, document content, chat messages) as a
  defense-in-depth layer below the request-level plug.

  ## Example

      changeset
      |> validate_no_hidden_unicode([:title, :content])
  """
  @spec validate_no_hidden_unicode(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate_no_hidden_unicode(%Ecto.Changeset{} = changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, cs ->
      value = get_change(cs, field)

      if is_binary(value) and contains_injection?(value) do
        add_error(cs, field, "contains disallowed hidden Unicode characters")
      else
        cs
      end
    end)
  end

  # Private

  defp maybe_add(list, category, true), do: [category | list]
  defp maybe_add(list, _category, false), do: list
end
