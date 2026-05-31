defmodule ISOMedia.Boxes.Handler do
  @moduledoc """
  Typed view of the `hdlr` Handler Reference Box.

  Layout (FullBox): pre_defined(32) · handler_type(4) · reserved(32)x3 ·
  name (UTF-8, NUL-terminated, to end of box).

  `name` is exposed without its trailing NUL; the original terminator is
  reproduced on encode.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :flags, :handler_type, :name]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          flags: <<_::24>>,
          handler_type: String.t(),
          name: String.t()
        }

  @doc "Decode an `hdlr` box into a `%Handler{}`."
  def decode(%Box{type: "hdlr", data: data}) do
    {version, flags, body} = FullBox.parse(data)

    <<_pre_defined::32, handler_type::binary-size(4), _reserved::binary-size(12), name_field::binary>> =
      body

    %__MODULE__{
      version: version,
      flags: flags,
      handler_type: handler_type,
      name: strip_nul(name_field)
    }
  end

  @doc "Encode a `%Handler{}` back into an `hdlr` box."
  def encode(%__MODULE__{} = h) do
    body = [<<0::32>>, h.handler_type, <<0::32, 0::32, 0::32>>, h.name, <<0>>]
    data = IO.iodata_to_binary(FullBox.encode(h.version, h.flags, body))
    %Box{type: "hdlr", data: data}
  end

  defp strip_nul(bin) do
    case :binary.split(bin, <<0>>) do
      [name | _] -> name
      [] -> ""
    end
  end
end
