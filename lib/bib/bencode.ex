defmodule Bib.Bencode do
  @moduledoc """
  Functions for encoding and decoding bencode data.
  Bencode data exists in two main places in bittorrent:
  - tracker responses (see `announce`)
  - the .torrent metainfo file. (see `MetaInfo` and `Bitfield`)
  """

  def encode(term)

  def encode(m) when is_map(m) do
    sorted_keys =
      m
      |> Map.keys()
      |> Enum.sort()

    dict_body =
      Enum.reduce(sorted_keys, <<>>, fn key, acc ->
        [acc | [encode(key), encode(Map.fetch!(m, key))]]
      end)

    ["d", dict_body, "e"]
  end

  def encode(s) when is_binary(s) do
    length = byte_size(s)
    length = "#{length}"
    [length, ":", s]
  end

  def encode(i) when is_integer(i) do
    ["i", "#{i}", "e"]
  end

  def encode(l) when is_list(l) do
    list_body =
      Enum.reduce(l, <<>>, fn element, acc ->
        [acc | encode(element)]
      end)

    ["l", list_body, "e"]
  end

  def decode(s) when is_binary(s) do
    {out, rest} =
      case s do
        <<"d", rest::binary>> ->
          decode_dict(rest, %{})

        <<"l", rest::binary>> ->
          decode_list(rest, [])

        <<"i", rest::binary>> ->
          decode_integer(rest)

        rest ->
          decode_string(rest)
      end

    {:ok, out, rest}
  end

  defp decode_dict(<<"e", rest::binary>>, acc) do
    {acc, rest}
  end

  defp decode_dict(s, acc) do
    {:ok, key, rest} = decode(s)
    {:ok, value, rest} = decode(rest)
    decode_dict(rest, Map.put(acc, key, value))
  end

  defp decode_list(<<"e", rest::binary>>, acc) do
    {:lists.reverse(acc), rest}
  end

  defp decode_list(s, acc) do
    {:ok, element, rest} = decode(s)
    decode_list(rest, [element | acc])
  end

  defp decode_integer(s) do
    {i, <<"e", rest::binary>>} = Integer.parse(s)
    {i, rest}
  end

  defp decode_string(s) do
    {length, <<":", r::binary>>} = Integer.parse(s)
    <<string::binary-size(length), rest::binary>> = r
    {string, rest}
  end
end
