defmodule ISOMedia.Boxes.Handler do
  @moduledoc """
  Typed view of the `hdlr` Handler Reference Box.

  Layout (FullBox): pre_defined(32) · handler_type(4) · reserved(32)x3 ·
  name (UTF-8, NUL-terminated, to end of box).

  `name` is exposed as the stripped name (the bytes before the first NUL),
  making it convenient to read or edit. `name_suffix` preserves the original
  terminator and any trailing bytes (everything from the first NUL onward, or
  empty when there is no NUL) so that encode reproduces the input byte-for-byte.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :flags, :handler_type, :name, :name_suffix]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          flags: <<_::24>>,
          handler_type: String.t(),
          name: String.t(),
          name_suffix: binary()
        }

  @doc "Decode an `hdlr` box into a `%Handler{}`."
  def decode(%Box{type: "hdlr", data: data}) do
    {version, flags, body} = FullBox.parse(data)

    <<_pre_defined::32, handler_type::binary-size(4), _reserved::binary-size(12), name_field::binary>> =
      body

    {name, name_suffix} =
      case :binary.split(name_field, <<0>>) do
        [name, tail] -> {name, <<0, tail::binary>>}
        [name] -> {name, <<>>}
      end

    %__MODULE__{
      version: version,
      flags: flags,
      handler_type: handler_type,
      name: name,
      name_suffix: name_suffix
    }
  end

  @doc "Encode a `%Handler{}` back into an `hdlr` box."
  def encode(%__MODULE__{} = h) do
    body = [<<0::32>>, h.handler_type, <<0::32, 0::32, 0::32>>, h.name, h.name_suffix]
    data = IO.iodata_to_binary(FullBox.encode(h.version, h.flags, body))
    %Box{type: "hdlr", data: data}
  end
end
