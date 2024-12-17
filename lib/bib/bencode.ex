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
    with {:ok, out, rest, position} <- decode_any(s, 0),
         {_, true} <- {:decoded_all_input, position == byte_size(s)} do
      {:ok, out, rest}
    end
  end

  defp decode_any(s, position) do
    case s do
      <<"d", rest::binary>> ->
        decode_dict(rest, %{}, position + 1)

      <<"l", rest::binary>> ->
        decode_list(rest, [], position + 1)

      <<"i", rest::binary>> ->
        decode_integer(rest, position + 1)

      rest ->
        decode_string(rest, position)
    end
  end

  defp decode_dict(<<"e", rest::binary>>, acc, position) do
    {:ok, acc, rest, position + 1}
  end

  defp decode_dict(<<>>, _acc, position) do
    {:error, "expecting to parse dict end 'e' character, got end of input", position}
  end

  defp decode_dict(s, acc, position) do
    with {:ok, key, rest, position} <- decode_string(s, position),
         {:ok, value, rest, position} <- decode_any(rest, position) do
      decode_dict(rest, Map.put(acc, key, value), position)
    end
  end

  defp decode_list(<<>>, _acc, position) do
    {:error, "expecting to parse list end 'e' character, got end of input", position}
  end

  defp decode_list(<<"e", rest::binary>>, acc, position) do
    {:ok, :lists.reverse(acc), rest, position + 1}
  end

  defp decode_list(s, acc, position) do
    with {:ok, element, rest, position} <- decode_any(s, position) do
      decode_list(rest, [element | acc], position)
    end
  end

  defp decode_integer(s, position) do
    with {_, {i, <<rest::binary>>}} <- {:integer_digits, Integer.parse(s)},
         position = position + (byte_size(s) - byte_size(rest)),
         {_, <<"e", rest::binary>>, position} <- {:integer_end, rest, position} do
      {:ok, i, rest, position + 1}
    else
      {:integer_digits, :error} ->
        {:error, "expecting to parse integer digits, got '#{take_byte(s)}'", position}

      {:integer_end, rest, position} ->
        {
          :error,
          "expecting to parse integer end 'e' character, got '#{take_byte(rest)}'",
          position
        }
    end
  end

  defp decode_string(s, position) do
    with {_, {length, <<rest::binary>>}, position} <-
           {:string_length, Integer.parse(s), position},
         position = position + (byte_size(s) - byte_size(rest)),
         {_, <<":", rest::binary>>, position} <- {:string_separator, rest, position},
         {_, <<string::binary-size(length), rest::binary>>, _length, position} <-
           {:string_body, rest, length, position + 1},
         position = position + length do
      {:ok, string, rest, position}
    else
      {:string_length, :error, position} ->
        {:error, "expecting to parse string length, got '#{take_byte(s)}'", position}

      {:string_separator, rest, position} ->
        {:error, "expecting to parse string separator ':', got '#{take_byte(rest)}'", position}

      {:string_body, _rest, length, position} ->
        {:error, "expecting to parse string body with length #{length}, input ended early",
         position}
    end
  end

  defp take_byte(s) do
    case s do
      <<>> ->
        <<>>

      <<b::binary-size(1), _rest::binary>> ->
        b
    end
  end
end
