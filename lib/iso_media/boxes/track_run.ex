defmodule ISOMedia.Boxes.TrackRun do
  @moduledoc "Typed view of the `trun` Track Run box (per-sample list)."
  import Bitwise
  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :sample_count, :data_offset, :first_sample_flags, :samples]

  @type sample :: %{
          duration: non_neg_integer() | nil,
          size: non_neg_integer() | nil,
          flags: non_neg_integer() | nil,
          composition_offset: integer() | nil
        }

  @type t :: %__MODULE__{
          version: 0 | 1 | nil,
          sample_count: non_neg_integer(),
          data_offset: integer() | nil,
          first_sample_flags: non_neg_integer() | nil,
          samples: [sample()]
        }

  @data_offset 0x000001
  @first_sample_flags 0x000004
  @sample_duration 0x000100
  @sample_size 0x000200
  @sample_flags 0x000400
  @sample_comp_offset 0x000800

  @doc "Decode a `trun` box."
  @spec decode(ISOMedia.Box.t()) :: t()
  def decode(%Box{type: "trun", data: data}) do
    {version, <<flags::24>>, <<sample_count::32, rest::binary>>} = FullBox.parse(data)
    {data_offset, rest} = take(rest, flags, @data_offset, :signed)
    {first_sample_flags, rest} = take(rest, flags, @first_sample_flags, :unsigned)
    samples = decode_samples(rest, sample_count, version, flags, [])

    %__MODULE__{
      version: version,
      sample_count: sample_count,
      data_offset: data_offset,
      first_sample_flags: first_sample_flags,
      samples: samples
    }
  end

  defp decode_samples(_bin, 0, _v, _flags, acc), do: Enum.reverse(acc)

  defp decode_samples(bin, n, version, flags, acc) do
    {duration, bin} = take(bin, flags, @sample_duration, :unsigned)
    {size, bin} = take(bin, flags, @sample_size, :unsigned)
    {sflags, bin} = take(bin, flags, @sample_flags, :unsigned)
    {coff, bin} = take_comp(bin, flags, version)
    sample = %{duration: duration, size: size, flags: sflags, composition_offset: coff}
    decode_samples(bin, n - 1, version, flags, [sample | acc])
  end

  defp take(bin, flags, mask, :unsigned) do
    if (flags &&& mask) != 0 do
      <<v::32, rest::binary>> = bin
      {v, rest}
    else
      {nil, bin}
    end
  end

  defp take(bin, flags, mask, :signed) do
    if (flags &&& mask) != 0 do
      <<v::signed-32, rest::binary>> = bin
      {v, rest}
    else
      {nil, bin}
    end
  end

  defp take_comp(bin, flags, version) do
    cond do
      (flags &&& @sample_comp_offset) == 0 -> {nil, bin}
      version == 1 -> (fn <<v::signed-32, r::binary>> -> {v, r} end).(bin)
      true -> (fn <<v::32, r::binary>> -> {v, r} end).(bin)
    end
  end

  @doc """
  Encode a `%TrackRun{}` into a `trun` box. Always writes data-offset + per-sample
  duration/size/flags; writes composition offsets (v1, signed) iff any sample has a
  nonzero offset. Writes `first_sample_flags` (32-bit, after data_offset) when non-nil.
  """
  @spec encode(t()) :: ISOMedia.Box.t()
  def encode(%__MODULE__{} = t) do
    has_comp = Enum.any?(t.samples, &((&1.composition_offset || 0) != 0))
    version = if has_comp, do: 1, else: 0

    fsf_flag = if t.first_sample_flags != nil, do: @first_sample_flags, else: 0

    flags =
      @data_offset ||| @sample_duration ||| @sample_size ||| @sample_flags ||| fsf_flag |||
        if has_comp, do: @sample_comp_offset, else: 0

    samples =
      for s <- t.samples, into: <<>> do
        base = <<s.duration::32, s.size::32, s.flags::32>>

        if has_comp do
          co = s.composition_offset || 0
          base <> <<co::signed-32>>
        else
          base
        end
      end

    fsf_bin =
      if t.first_sample_flags != nil,
        do: <<t.first_sample_flags::32>>,
        else: <<>>

    body =
      <<length(t.samples)::32, t.data_offset::signed-32>> <>
        fsf_bin <> samples

    %Box{type: "trun", data: FullBox.encode_data(version, <<flags::24>>, body)}
  end
end
