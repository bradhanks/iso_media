defmodule ISOMedia.OffsetsPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Box
  alias ISOMedia.Support.MP4Builder

  # A generated movie: 1..5 chunks of 1..8 random bytes each.
  defp movie do
    gen all(chunks <- list_of(binary(min_length: 1, max_length: 8), min_length: 1, max_length: 5)) do
      MP4Builder.build(chunks)
    end
  end

  # A structural edit applied to the top-level box list (never touches mdat bytes).
  defp edit do
    one_of([
      # insert a free box at a random top-level index
      tuple({constant(:insert_free), integer(0..3), integer(0..3)}),
      constant(:faststart)
    ])
  end

  defp apply_edit({:insert_free, size, where}, boxes) do
    free = %Box{type: "free", data: :binary.copy(<<0>>, size)}
    idx = rem(where, length(boxes) + 1)
    {:list, List.insert_at(boxes, idx, free)}
  end

  defp apply_edit(:faststart, boxes), do: {:faststart, ISOMedia.faststart(boxes)}

  # Returns the chunk offsets currently in the tree (document order).
  defp offsets(boxes) do
    boxes
    |> Box.find_all(~w(moov trak mdia minf stbl stco))
    |> Enum.flat_map(&ISOMedia.Boxes.ChunkOffset.decode(&1).offsets)
  end

  property "after any structural edits + fix, every chunk resolves to its original bytes" do
    check all(
            %{binary: bin, chunks: chunks} <- movie(),
            edits <- list_of(edit(), max_length: 4)
          ) do
      {:ok, boxes} = ISOMedia.parse(bin)

      # Apply edits in sequence; :faststart already fixes offsets, otherwise fix at the end.
      {tag, edited} =
        Enum.reduce(edits, {:list, boxes}, fn e, {_t, acc} -> apply_edit(e, acc) end)

      fixed = if tag == :faststart, do: edited, else: ISOMedia.fix_chunk_offsets(edited)
      out = ISOMedia.serialize(fixed)

      chunks
      |> Enum.zip(offsets(fixed))
      |> Enum.each(fn {chunk, off} ->
        assert binary_part(out, off, byte_size(chunk)) == chunk,
               "chunk #{inspect(chunk)} not found at offset #{off}"
      end)
    end
  end

  property "no-op: fixing an unedited tree serializes identically to the input" do
    check all(%{binary: bin} <- movie()) do
      {:ok, boxes} = ISOMedia.parse(bin)
      assert ISOMedia.serialize(ISOMedia.fix_chunk_offsets(boxes)) == bin
    end
  end

  property "fix_chunk_offsets is idempotent" do
    check all(%{binary: bin} <- movie(), pad <- integer(0..40)) do
      {:ok, boxes} = ISOMedia.parse(bin)
      edited = List.insert_at(boxes, 1, %Box{type: "free", data: :binary.copy(<<0>>, pad)})
      once = ISOMedia.fix_chunk_offsets(edited)
      twice = ISOMedia.fix_chunk_offsets(once)
      assert ISOMedia.serialize(twice) == ISOMedia.serialize(once)
    end
  end

  property "round-trip is preserved (source_offset/size never leak into output)" do
    check all(%{binary: bin} <- movie()) do
      {:ok, boxes} = ISOMedia.parse(bin)
      assert ISOMedia.serialize(boxes) == bin
    end
  end
end
