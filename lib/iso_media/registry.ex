defmodule ISOMedia.Registry do
  @moduledoc "Classifies which box types are containers (hold child boxes)."

  @containers ~w(
    moov trak mdia minf stbl dinf edts udta mvex moof traf
    mfra meco strk sinf schi
  )

  @doc "True when `type` is a known container box type."
  def container?(type) when is_binary(type), do: type in @containers
end
