# todo
# - [ ] tcp listener to spawn peers when remotes connect to us
# - [x] figure out what `choke` state means
# - [x] figure out what `interested` state means
# - [x] send handshake
# - [x] receive handshake
# - [x] handle `choke`
# - [x] handle `unchoke`
# - [x] handle `interested`
# - [x] handle `not interested`
# - [x] handle `have`
# - [x] handle `bitfield`
# - [ ] handle `request`
# - [ ] handle `piece`
# - [ ] handle `cancel`
# - [ ] send `interested` when we are interested
# - [ ] send `not_interested` when we are not interested
# - [ ] send `have` to torrent_state when we download/checksum piece
# - [ ] figure out 16kB chunks for pieces
# - [ ] file made of pieces (torrent-defined length) made of chunks (16kB length)
defmodule Bib.Peer do
  @behaviour :gen_statem

  alias Bib.{TorrentState, Bitfield, PeerSupervisor}

  require Logger

  defmodule State do
    defstruct peer_is_choking_me: true,
              i_am_choking_peer: true,
              peer_is_interested_in_me: false,
              i_am_interested_in_peer: false
  end

  defmodule Data do
    defstruct [
      :torrent_file,
      :download_location,
      :socket,
      :peer_id,
      :remote_peer_address,
      :remote_peer_id,
      :info_hash,
      :my_bitfield,
      :peer_bitfield,
      :pieces
    ]
  end

  @bittorrent_protocol_length_length 1
  @bittorrent_protocol_length 19
  @reserved_bytes_length 8
  @info_hash_length 20
  @peer_id_length 20

  @handshake_length @bittorrent_protocol_length_length +
                      @bittorrent_protocol_length +
                      @reserved_bytes_length +
                      @info_hash_length +
                      @peer_id_length

  def connect(torrent_file, peer_args) do
    PeerSupervisor.start_child(torrent_file, peer_args)
  end

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    :gen_statem.start_link(__MODULE__, args, [])
  end

  @doc """
  send a message to `peer` asynchronously, with no reply
  """
  def cast(peer, message) do
    :gen_statem.cast(peer, message)
  end

  @impl :gen_statem
  def init(%{
        torrent_file: torrent_file,
        download_location: download_location,
        remote_peer_address: peer_address,
        remote_peer_id: remote_peer_id,
        info_hash: info_hash,
        peer_id: peer_id,
        pieces: pieces
      }) do
    state = %State{
      peer_is_choking_me: true,
      i_am_choking_peer: true,
      peer_is_interested_in_me: false,
      i_am_interested_in_peer: false
    }

    data = %Data{
      torrent_file: torrent_file,
      download_location: download_location,
      remote_peer_address: peer_address,
      remote_peer_id: remote_peer_id,
      info_hash: info_hash,
      peer_id: peer_id,
      pieces: pieces
    }

    Logger.metadata(remote_peer_address: peer_address, remote_peer_id: remote_peer_id)

    {:ok, state, data, [{:next_event, :internal, :connect_to_peer}]}
  end

  @impl :gen_statem
  def handle_event(:internal, :connect_to_peer, _state, data) do
    {host, port} = data.remote_peer_address

    {:ok, ip} =
      host
      |> to_charlist()
      |> :inet.parse_address()

    case :gen_tcp.connect(ip, port, [
           :binary,
           {:packet, 0},
           {:active, false}
         ]) do
      {:ok, socket} ->
        Logger.debug("connected to #{inspect(data.remote_peer_address)}")

        {:keep_state, %Data{data | socket: socket}, [{:next_event, :internal, :send_handshake}]}

      {:error, error} ->
        Logger.error(
          "could not connect to peer {#{inspect(ip)}, #{inspect(port)}}, shutting down: #{inspect(error)}"
        )

        {:stop, :normal}
    end
  end

  def handle_event(:internal, :send_handshake, _state, data) do
    :ok =
      :gen_tcp.send(data.socket, [
        19,
        <<"BitTorrent protocol">>,
        <<0, 0, 0, 0, 0, 0, 0, 0>>,
        data.info_hash,
        data.peer_id
      ])

    Logger.debug("sent handshake to #{inspect(data.remote_peer_address)}")

    {:keep_state_and_data, [{:next_event, :internal, :receive_handshake}]}
  end

  def handle_event(:internal, :receive_handshake, _state, data) do
    Logger.debug("waiting for handshake response")

    case :gen_tcp.recv(data.socket, @handshake_length) do
      {:ok, packet} ->
        Logger.debug("got handshake (raw): #{inspect(packet)}")

        case packet do
          <<19, "BitTorrent protocol",
            _reserved_bytes_length::binary-size(@reserved_bytes_length),
            challenge_info_hash::binary-size(@info_hash_length),
            remote_peer_id::binary-size(@peer_id_length)>> ->
            Logger.debug("does info hash match? #{challenge_info_hash == data.info_hash}")
            Logger.debug("does expected peer id match? #{remote_peer_id == data.remote_peer_id}")

            if challenge_info_hash == data.info_hash &&
                 remote_peer_id ==
                   data.remote_peer_id do
              Logger.debug("HANDSHAKE SUCCESSFUL")
              :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
              :keep_state_and_data
            else
              Logger.debug("info hashes or peer ids did not match, shutting down")
              {:stop, :normal}
            end

          nonmatching_handshake ->
            Logger.debug(
              "did not receive correct handshake, shutting down. Packet length was #{byte_size(nonmatching_handshake)}. expected #{@handshake_length}"
            )

            {:stop, :normal}
        end

      {:error, error} ->
        Logger.debug("got error: #{inspect(error)}")
        :keep_state_and_data
    end
  end

  # keepalive
  def handle_event(:info, {:tcp, _socket, <<>>}, _state, data) do
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    :keep_state_and_data
  end

  # choke = "I am uploading, or not"
  # interested = "you have something I want, or not"
  def handle_event(:info, {:tcp, _socket, packet}, _state, _data) do
    peer_message = decode_peer_message(packet)
    {:keep_state_and_data, [{:next_event, :internal, {:peer_message, peer_message}}]}
  end

  def handle_event(:info, {:tcp_closed, _socket}, _state, _data) do
    Logger.debug("tcp closed, shutting down")
    {:stop, :normal}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :choke}, state, data) do
    Logger.debug("received choke")
    state = %State{state | peer_is_choking_me: true}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :unchoke}, state, data) do
    Logger.debug("received unchoke")
    state = %State{state | peer_is_choking_me: false}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :interested}, state, data) do
    Logger.debug("received interested")
    state = %State{state | peer_is_interested_in_me: true}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :not_interested}, state, data) do
    Logger.debug("received not_interested")
    state = %State{state | peer_is_interested_in_me: false}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data}
  end

  def handle_event(:internal, {:peer_message, {:have, index}}, _state, data) do
    data = %Data{data | peer_bitfield: Bitfield.set_bit(data.peer_bitfield, index)}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:keep_state, data}
  end

  def handle_event(:internal, {:peer_message, {:bitfield, bitfield}}, _state, data) do
    data = %Data{data | peer_bitfield: bitfield}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:keep_state, data}
  end

  def handle_event(
        :internal,
        {:peer_message, {:request, _index, _begin, _length}},
        %{i_am_choking_peer: true} = _state,
        data
      ) do
    {:keep_state, data}
  end

  # TODO what do we do here on choked vs unchoked?
  def handle_event(
        :internal,
        {:peer_message, {:request, index, begin, length}},
        %{i_am_choking_peer: false} = _state,
        data
      ) do
    Logger.debug("received request: #{index}, #{begin}, #{length}")
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:keep_state, data}
  end

  def handle_event(:internal, {:peer_message, {:piece, index, begin, piece}}, _state, data) do
    Logger.debug("received piece: #{index}, #{begin}, and piece of length #{byte_size(piece)}")
    {:ok, fd} = :file.open(data.download_location, [:write, :read, :raw, :binary])

    :ok = :file.pwrite(fd, begin, piece)

    :ok = :file.sync(fd)

    {:ok, bytes_written} = :file.pread(fd, begin, data.piece_length)

    if :crypto.hash(:sha, bytes_written) == Enum.at(data.pieces, index) do
      Logger.debug("received piece #{index} and hashes match, sending have")
      TorrentState.have(data.torrent_file, index)
    else
      Logger.debug("piece #{index} did not match hash")
    end

    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])

    {:keep_state, data}
  end

  def handle_event(:internal, {:peer_message, {:cancel, index, begin, length}}, _state, data) do
    Logger.debug("received cancel: #{index}, #{begin}, #{length}")
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:keep_state, data}
  end

  def handle_event(:internal, {:peer_message, peer_message}, _state, data) do
    Logger.warning("unhandled message: #{inspect(peer_message)}")
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    :keep_state_and_data
  end

  def handle_event(:cast, {:have, index}, _state, %Data{} = data) do
    data = %Data{data | my_bitfield: Bitfield.set_bit(data.my_bitfield, index)}
    {:keep_state, data}
  end

  defp decode_peer_message(<<tag_byte, rest::binary>>) do
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

  @impl :gen_statem
  def callback_mode() do
    :handle_event_function
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end
end
