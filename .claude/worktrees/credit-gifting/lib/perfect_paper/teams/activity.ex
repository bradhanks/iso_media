defmodule PerfectPaper.Teams.Activity do
  @moduledoc "Parses a raw Bot Framework Activity map into a normalized struct."
  @type t :: %__MODULE__{
          type: String.t() | nil,
          text: String.t() | nil,
          aad_object_id: String.t() | nil,
          tenant_id: String.t() | nil,
          service_url: String.t() | nil,
          conversation_reference: map()
        }
  defstruct [:type, :text, :aad_object_id, :tenant_id, :service_url, conversation_reference: %{}]

  @doc "Builds a normalized Activity from the raw inbound JSON map."
  @spec parse(map()) :: t()
  def parse(%{} = raw) do
    %__MODULE__{
      type: raw["type"],
      text: raw["text"] |> normalize_text(),
      aad_object_id: get_in(raw, ["from", "aadObjectId"]),
      tenant_id: get_in(raw, ["channelData", "tenant", "id"]),
      service_url: raw["serviceUrl"],
      conversation_reference: %{
        "bot" => raw["recipient"],
        "user" => raw["from"],
        "conversation" => raw["conversation"],
        "channelId" => raw["channelId"],
        "serviceUrl" => raw["serviceUrl"]
      }
    }
  end

  @doc "Returns the lowercased first word of the message text (the command), or nil."
  @spec command(t()) :: String.t() | nil
  def command(%__MODULE__{text: nil}), do: nil

  def command(%__MODULE__{text: text}),
    do: text |> String.split() |> List.first() |> String.downcase()

  defp normalize_text(nil), do: nil
  defp normalize_text(t) when is_binary(t), do: String.trim(t)
end
