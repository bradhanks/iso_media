defmodule ISOMedia.UntrustedInputTest do
  @moduledoc """
  Hostile-input bounds for the sample-table / track-run decoders: a box may declare
  a count far larger than the bytes that back it. The decoder must reject it *before*
  allocating/expanding, not after. Each bomb runs in a heap-bounded process so an
  unbounded allocation kills only that process (a clear RED) instead of the VM.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias ISOMedia.{Box, SampleTable}
  alias ISOMedia.Boxes.TrackRun

  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  # Run `fun` in a process capped at ~400MB. Returns:
  #   {:raised, message} — fun raised ArgumentError (the desired bounded behavior)
  #   {:no_raise, _}      — fun returned without raising
  #   {:killed, reason}   — process exceeded the heap cap (allocation bomb) or died
  defp run_bounded(fun) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              fun.()
              {:no_raise, nil}
            rescue
              e in ArgumentError -> {:raised, Exception.message(e)}
            end

          send(parent, {:done, self(), result})
        end,
        [:monitor, max_heap_size: %{size: 50_000_000, kill: true, error_logger: false}]
      )

    receive do
      {:done, ^pid, result} -> result
      {:DOWN, ^ref, :process, ^pid, reason} -> {:killed, reason}
    after
      15_000 -> {:timeout, nil}
    end
  end

  # A trak whose chunk structure implies exactly one sample, but whose `stsz` claims
  # a huge constant-size count. Bounded decode must reject before duplicating.
  defp stsz_bomb_trak(count) do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf("stts", <<0, 0, 0, 0, 1::32, 1::32, 100::32>>)
    stsc = leaf("stsc", <<0, 0, 0, 0, 1::32, 1::32, 1::32, 1::32>>)
    stsz = leaf("stsz", <<0, 0, 0, 0, 1::32, count::32>>)
    stco = leaf("stco", <<0, 0, 0, 0, 1::32, 1000::32>>)
    stbl = container("stbl", stsd <> stts <> stsc <> stsz <> stco)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 7::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    trak_box
  end

  defp stts_bomb_trak(run_length) do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf("stts", <<0, 0, 0, 0, 1::32, run_length::32, 100::32>>)
    stsc = leaf("stsc", <<0, 0, 0, 0, 1::32, 1::32, 1::32, 1::32>>)
    stsz = leaf("stsz", <<0, 0, 0, 0, 0::32, 1::32, 10::32>>)
    stco = leaf("stco", <<0, 0, 0, 0, 1::32, 1000::32>>)
    stbl = container("stbl", stsd <> stts <> stsc <> stsz <> stco)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 7::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    trak_box
  end

  defp ctts_bomb_trak(run_length) do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf("stts", <<0, 0, 0, 0, 1::32, 1::32, 100::32>>)
    stsc = leaf("stsc", <<0, 0, 0, 0, 1::32, 1::32, 1::32, 1::32>>)
    stsz = leaf("stsz", <<0, 0, 0, 0, 0::32, 1::32, 10::32>>)
    stco = leaf("stco", <<0, 0, 0, 0, 1::32, 1000::32>>)
    ctts = leaf("ctts", <<0, 0, 0, 0, 1::32, run_length::32, 0::32>>)
    stbl = container("stbl", stsd <> stts <> stsc <> stsz <> stco <> ctts)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 7::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    trak_box
  end

  @huge 0xFFFFFFFF

  test "stsz constant-size count exceeding chunk-implied samples is rejected before allocation" do
    assert {:raised, msg} = run_bounded(fn -> SampleTable.build(stsz_bomb_trak(@huge)) end)
    assert msg =~ ~r/stsz/
  end

  test "stts run-length expansion is bounded by sample_count" do
    assert {:raised, msg} = run_bounded(fn -> SampleTable.build(stts_bomb_trak(@huge)) end)
    assert msg =~ ~r/stts/
  end

  test "ctts run-length expansion is bounded by sample_count" do
    assert {:raised, msg} = run_bounded(fn -> SampleTable.build(ctts_bomb_trak(@huge)) end)
    assert msg =~ ~r/ctts/
  end

  test "trun with no per-sample fields and a huge sample_count is rejected" do
    # flags = 0x000001 (data-offset present, no per-sample bits) → each sample would
    # consume zero bytes, so sample_count is unbacked by the payload.
    data = <<0::8, 0x000001::24, @huge::32, 0::signed-32>>
    box = %Box{type: "trun", data: data}
    assert {:raised, msg} = run_bounded(fn -> TrackRun.decode(box) end)
    assert msg =~ ~r/trun/
  end

  test "a well-formed trun still decodes" do
    # flags = data-offset + sample-duration + sample-size; 2 samples.
    flags = 0x000001 ||| 0x000100 ||| 0x000200
    data = <<0::8, flags::24, 2::32, 0::signed-32, 100::32, 10::32, 100::32, 20::32>>
    box = %Box{type: "trun", data: data}
    decoded = TrackRun.decode(box)
    assert decoded.sample_count == 2
    assert [%{duration: 100, size: 10}, %{duration: 100, size: 20}] = decoded.samples
  end
end
