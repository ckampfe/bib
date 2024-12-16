defmodule Bib.Peer.Protocol do
  @moduledoc """
  The peer protocol is used for sending and receiving data to and
  from remote peers over TCP.
  """

  alias Bib.Bitfield

  def decode(<<tag_byte, rest::binary>>) do
    case tag_byte do
      0 ->
        :choke

      1 ->
        :unchoke

      2 ->
        :interested

      3 ->
        :not_interested

      4 ->
        {:have, :binary.decode_unsigned(rest)}

      5 ->
        {:bitfield, rest}

      6 ->
        <<index::integer-32, begin::integer-32, length::integer-32>> = rest
        {:request, index, begin, length}

      7 ->
        <<index::integer-32, begin::integer-32, piece::binary>> = rest
        {:piece, index, begin, piece}

      8 ->
        <<index::integer-32, begin::integer-32, length::integer-32>> = rest
        {:cancel, index, begin, length}
    end
  end

  def encode(message) do
    case message do
      :keepalive ->
        []

      :choke ->
        [0]

      :unchoke ->
        [1]

      :interested ->
        [2]

      :not_interested ->
        [3]

      {:have, index} ->
        [4, <<index::unsigned-integer-32>>]

      {:bitfield, bitfield} ->
        [5, Bitfield.pad_to_binary(bitfield)]

      {:request, index, begin, length} ->
        [
          6,
          <<index::unsigned-integer-32>>,
          <<begin::unsigned-integer-32>>,
          <<length::unsigned-integer-32>>
        ]

      {:piece, index, begin, block} ->
        [
          7,
          <<index::unsigned-integer-32>>,
          <<begin::unsigned-integer-32>>,
          block
        ]

      {:cancel, index, begin, length} ->
        [
          8,
          <<index::unsigned-integer-32>>,
          <<begin::unsigned-integer-32>>,
          <<length::unsigned-integer-32>>
        ]
    end
  end
end
