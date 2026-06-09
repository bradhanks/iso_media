defmodule ISOMedia.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ISOMedia.Box

  @moduletag :tmp_dir

  defp build_mp4!(dir) do
    path = Path.join(dir, "movie.mp4")
    boxes = [%Box{type: "free", data: :binary.copy(<<3>>, 2000), size_mode: :compact}]
    :ok = ISOMedia.write(path, boxes)
    {path, ISOMedia.serialize(boxes)}
  end

  defp call(conn, opts), do: ISOMedia.Plug.call(conn, ISOMedia.Plug.init(opts))

  test "GET full file via :root => 200 with accept-ranges", %{tmp_dir: dir} do
    {_path, full} = build_mp4!(dir)
    conn = call(conn(:get, "/movie.mp4"), root: dir)
    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert conn.resp_body == full
  end

  test "Range GET => 206 with exact slice", %{tmp_dir: dir} do
    {_path, full} = build_mp4!(dir)
    conn = call(conn(:get, "/movie.mp4") |> put_req_header("range", "bytes=10-19"), root: dir)
    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 10-19/#{byte_size(full)}"]
    assert conn.resp_body == :binary.part(full, 10, 10)
  end

  test "HEAD => 200 headers, empty body", %{tmp_dir: dir} do
    {_path, _full} = build_mp4!(dir)
    conn = call(conn(:head, "/movie.mp4"), root: dir)
    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "missing file => 404", %{tmp_dir: dir} do
    conn = call(conn(:get, "/nope.mp4"), root: dir)
    assert conn.status == 404
  end

  test "path traversal is refused => 404", %{tmp_dir: dir} do
    build_mp4!(dir)
    conn = call(conn(:get, "/../../etc/passwd"), root: dir)
    assert conn.status == 404
  end

  test "resolver returning a tree works" do
    boxes = [%Box{type: "free", data: <<1, 2, 3, 4>>, size_mode: :compact}]
    resolver = fn _conn -> {:ok, boxes} end
    conn = call(conn(:get, "/x"), resolver: resolver)
    assert conn.status == 200
    assert conn.resp_body == ISOMedia.serialize(boxes)
  end
end
