# https://wiki.theory.org/BitTorrentSpecification
#
# TORRENTS have PIECES which have BLOCKS
#
# todo
# - [ ] tcp listener to spawn peers when remotes connect to us
# - [x] figure out what `choke` state means
# - [x] figure out what `interested` state means
# - [x] send handshake
# - [x] receive handshake
# - [x] handle `keepalive`
# - [x] handle `choke`
# - [x] handle `unchoke`
# - [x] handle `interested`
# - [x] handle `not interested`
# - [x] handle `have`
# - [x] handle `bitfield`
# - [ ] handle `request`
# - [x] handle `piece`
# - [ ] handle `cancel`
# - [x] send `interested` when we are interested
# - [x] send `not_interested` when we are not interested
# - [x] send `have` to torrent_state when we download/checksum piece
# - [x] interest timer
# - [x] keepalive timer
# - [x] figure out 16kB blocks for pieces
defmodule Bib.Peer do
  @behaviour :gen_statem

  alias Bib.FileOps
  alias Bib.{Torrent, Bitfield, PeerSupervisor, MetaInfo}
  alias Bib.Peer.Protocol

  require Logger

  defmodule State do
    defstruct peer_is_choking_me: true,
              i_am_choking_peer: true,
              peer_is_interested_in_me: false,
              i_am_interested_in_peer: false
  end

  defmodule Data do
    @enforce_keys [
      :metainfo,
      :torrent_file,
      :download_location,
      :peer_id,
      :remote_peer_address,
      :remote_peer_id,
      :my_pieces,
      :block_length
    ]

    defstruct [
      :metainfo,
      :torrent_file,
      :download_location,
      :socket,
      :peer_id,
      :remote_peer_address,
      :remote_peer_id,
      :my_pieces,
      :peer_pieces,
      :interest_interval,
      :keepalive_interval,
      :block_length
    ]
  end

  defmodule Args do
    defstruct [
      :metainfo,
      :torrent_file,
      :download_location,
      :remote_peer_address,
      :remote_peer_id,
      :peer_id,
      :pieces,
      :block_length
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
  def init(%Args{} = args) do
    state = %State{
      peer_is_choking_me: true,
      i_am_choking_peer: true,
      peer_is_interested_in_me: false,
      i_am_interested_in_peer: false
    }

    data = %Data{
      metainfo: args.metainfo,
      torrent_file: args.torrent_file,
      download_location: args.download_location,
      remote_peer_address: args.remote_peer_address,
      remote_peer_id: args.remote_peer_id,
      peer_id: args.peer_id,
      my_pieces: args.pieces,
      interest_interval: :timer.minutes(1),
      keepalive_interval: :timer.seconds(30),
      block_length: args.block_length
    }

    Logger.metadata(
      remote_peer_address: args.remote_peer_address,
      remote_peer_id: args.remote_peer_id
    )

    {:ok, state, data, [{:next_event, :internal, :connect_to_peer}]}
  end

  @impl :gen_statem
  def handle_event(:internal, :connect_to_peer, %State{} = _state, %Data{} = data) do
    {host, port} = data.remote_peer_address

    {:ok, ip} =
      host
      |> to_charlist()
      |> :inet.parse_address()

    case :gen_tcp.connect(ip, port, [
           :binary,
           {:packet, 0},
           {:active, false},
           {:send_timeout, :timer.seconds(5)}
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

  def handle_event(:internal, :send_handshake, %State{} = _state, %Data{} = data) do
    :ok =
      :gen_tcp.send(data.socket, [
        19,
        <<"BitTorrent protocol">>,
        <<0, 0, 0, 0, 0, 0, 0, 0>>,
        MetaInfo.info_hash(data.metainfo),
        data.peer_id
      ])

    Logger.debug("sent handshake to #{inspect(data.remote_peer_address)}")

    {:keep_state_and_data, [{:next_event, :internal, :receive_handshake}]}
  end

  def handle_event(:internal, :receive_handshake, %State{} = _state, %Data{} = data) do
    Logger.debug("waiting for handshake response")

    case :gen_tcp.recv(data.socket, @handshake_length) do
      {:ok, packet} ->
        Logger.debug("got handshake (raw): #{inspect(packet)}")

        case packet do
          <<19, "BitTorrent protocol",
            _reserved_bytes_length::binary-size(@reserved_bytes_length),
            challenge_info_hash::binary-size(@info_hash_length),
            remote_peer_id::binary-size(@peer_id_length)>> ->
            Logger.debug(
              "does info hash match? #{challenge_info_hash == MetaInfo.info_hash(data.metainfo)}"
            )

            Logger.debug("does expected peer id match? #{remote_peer_id == data.remote_peer_id}")

            if challenge_info_hash == MetaInfo.info_hash(data.metainfo) &&
                 remote_peer_id ==
                   data.remote_peer_id do
              Logger.debug("HANDSHAKE SUCCESSFUL")

              :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
              bitfield_encoded = Bib.Peer.Protocol.encode({:bitfield, data.my_pieces})
              Logger.debug("sent bitfield: #{inspect(bitfield_encoded)}")
              :gen_tcp.send(data.socket, bitfield_encoded)

              {
                :keep_state_and_data,
                [
                  {{:timeout, :interest_timer}, data.interest_interval, :ok},
                  {{:timeout, :keepalive_timer}, data.keepalive_interval, :ok}
                ]
              }
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
  def handle_event(:info, {:tcp, _socket, <<>>}, %State{} = _state, %Data{} = data) do
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    :keep_state_and_data
  end

  # choke = "I am uploading, or not"
  # interested = "you have something I want, or not"
  def handle_event(:info, {:tcp, _socket, packet}, %State{} = _state, %Data{} = _data) do
    peer_message = Bib.Peer.Protocol.decode(packet)
    {:keep_state_and_data, [{:next_event, :internal, {:peer_message, peer_message}}]}
  end

  def handle_event(:info, {:tcp_closed, _socket}, %State{} = _state, %Data{} = _data) do
    Logger.debug("tcp closed, shutting down")
    {:stop, :normal}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :choke}, %State{} = state, %Data{} = data) do
    Logger.debug("received choke")
    state = %State{state | peer_is_choking_me: true}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data}
  end

  def handle_event(
        :internal,
        {:peer_message, :unchoke},
        %State{i_am_interested_in_peer: true} = state,
        %Data{} = data
      ) do
    Logger.debug("received unchoke, downloading")
    state = %State{state | peer_is_choking_me: false}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data, [{:next_event, :internal, :request_blocks}]}
  end

  def handle_event(
        :internal,
        :request_blocks,
        %State{peer_is_choking_me: true} = _state,
        %Data{} = _data
      ) do
    Logger.debug("not requesting blocks, peer choked me before I could request")
    :keep_state_and_data
  end

  def handle_event(
        :internal,
        :request_blocks,
        %State{i_am_interested_in_peer: false} = _state,
        %Data{} = _data
      ) do
    Logger.debug("not requesting blocks, i am no longer interested in peer")
    :keep_state_and_data
  end

  def handle_event(
        :internal,
        :request_blocks,
        %State{peer_is_choking_me: false} = _state,
        %Data{} = data
      ) do
    case Bitfield.random_wanted_piece(data.peer_pieces, data.my_pieces) do
      nil ->
        Logger.debug("no random wanted piece")
        :keep_state_and_data

      index ->
        Logger.debug("randomly downloading piece #{index}")

        blocks =
          MetaInfo.blocks_for_piece(data.metainfo, index, data.block_length)

        requests =
          Enum.map(blocks, fn {offset, length} -> {:request, index, offset, length} end)

        Enum.each(requests, fn request ->
          Logger.debug("requesting #{inspect(request)}")
          encoded = Protocol.encode(request)
          :gen_tcp.send(data.socket, encoded)
        end)

        :keep_state_and_data
    end
  end

  def handle_event(
        :internal,
        {:peer_message, :unchoke},
        %State{i_am_interested_in_peer: false} = state,
        data
      ) do
    Logger.debug("received unchoke, still not interested, doing nothing")
    state = %State{state | peer_is_choking_me: false}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :interested}, %State{} = state, %Data{} = data) do
    Logger.debug("received interested")
    state = %State{state | peer_is_interested_in_me: true}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :not_interested}, %State{} = state, %Data{} = data) do
    Logger.debug("received not_interested")
    state = %State{state | peer_is_interested_in_me: false}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:next_state, state, data}
  end

  def handle_event(:internal, {:peer_message, {:have, index}}, _state, %Data{} = data) do
    Logger.debug("received have from peer for index #{index}, updating peer bitfield")
    data = %Data{data | peer_pieces: Bitfield.set_bit(data.peer_pieces, index)}
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:keep_state, data}
  end

  def handle_event(
        :internal,
        {:peer_message, {:bitfield, bitfield}},
        %State{} = state,
        %Data{} = data
      ) do
    if byte_size(bitfield) == byte_size(Bitfield.pad_to_binary(data.my_pieces)) do
      Logger.debug("received good bitfield")
      data = %Data{data | peer_pieces: bitfield}

      if Bitfield.right_has_some_left_doesnt_have(data.my_pieces, data.peer_pieces) do
        Logger.debug("I am interested in peer due to bitfield")
        state = %State{state | i_am_interested_in_peer: true}
        :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
        {:next_state, state, data}
      else
        Logger.debug("I am not interested in peer due to bitfield")
        :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
        {:keep_state, data}
      end
    else
      Logger.debug("received bad bitfield, shutting down")
      {:stop, :normal}
    end
  end

  def handle_event(
        :internal,
        {:peer_message, {:request, _index, _begin, _length}},
        %State{i_am_choking_peer: true} = _state,
        %Data{} = data
      ) do
    {:keep_state, data}
  end

  # TODO what do we do here on choked vs unchoked?
  def handle_event(
        :internal,
        {:peer_message, {:request, index, begin, length}},
        %State{i_am_choking_peer: false} = _state,
        %Data{} = data
      ) do
    Logger.debug("received request, sending block for: #{index}, #{begin}, #{length}")
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:keep_state, data}
  end

  def handle_event(
        :internal,
        {:peer_message, {:piece, index, begin, block}},
        %State{} = _state,
        %Data{} = data
      ) do
    Logger.debug("received block for index #{index}, begin #{begin}, length #{byte_size(block)}")

    case FileOps.write_block_and_verify_piece(
           Path.join([data.download_location, MetaInfo.name(data.metainfo)]),
           data.metainfo,
           index,
           begin,
           block
         ) do
      {:ok, true} ->
        Logger.debug(
          "received all of piece #{index} and hashes match, sending have to Torrent process, and downloading another piece"
        )

        :ok = Torrent.have(data.torrent_file, index)

        data = %Data{data | my_pieces: Bitfield.set_bit(data.my_pieces, index)}

        :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])

        {:keep_state, data, [{:next_event, :internal, :request_blocks}]}

      {:ok, false} ->
        Logger.debug("piece #{index} did not match hash, piece is not complete yet")
        :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
        {:keep_state, data}
    end
  end

  def handle_event(
        :internal,
        {:peer_message, {:cancel, index, begin, length}},
        %State{} = _state,
        %Data{} = data
      ) do
    Logger.debug("received cancel: #{index}, #{begin}, #{length}")
    :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
    {:keep_state, data}
  end

  # def handle_event(:internal, {:peer_message, peer_message}, _state, data) do
  #   Logger.warning("unhandled message: #{inspect(peer_message)}")
  #   :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
  #   :keep_state_and_data
  # end

  def handle_event({:timeout, :interest_timer}, :ok, %State{} = state, %Data{} = data) do
    if Bitfield.right_has_some_left_doesnt_have(data.my_pieces, data.peer_pieces) do
      # interested
      Logger.debug("I am interested")

      encoded = Protocol.encode(:interested)

      Logger.debug("sent interested")

      :gen_tcp.send(data.socket, encoded)

      if state.i_am_interested_in_peer do
        {
          :keep_state_and_data,
          [{{:timeout, :interest_timer}, data.interest_interval, :ok}]
        }
      else
        {
          :next_state,
          %State{state | i_am_interested_in_peer: true},
          data,
          [{{:timeout, :interest_timer}, data.interest_interval, :ok}]
        }
      end
    else
      Logger.debug("I am not interested")

      # not interested
      Logger.debug("sending not interested")

      encoded = Protocol.encode(:not_interested)

      Logger.debug("sent not interested #{inspect(encoded)}")

      :gen_tcp.send(data.socket, encoded)

      if state.i_am_interested_in_peer do
        {
          :next_state,
          %State{state | i_am_interested_in_peer: false},
          data,
          [{{:timeout, :interest_timer}, data.interest_interval, :ok}]
        }
      else
        {
          :keep_state_and_data,
          [{{:timeout, :interest_timer}, data.interest_interval, :ok}]
        }
      end
    end
  end

  def handle_event({:timeout, :keepalive_timer}, :ok, %State{} = _state, %Data{} = data) do
    :gen_tcp.send(data.socket, Bib.Peer.Protocol.encode(:keepalive))

    Logger.debug("sent keepalive")

    {
      :keep_state_and_data,
      [{{:timeout, :keepalive_timer}, data.keepalive_interval, :ok}]
    }
  end

  def handle_event(:cast, {:have, index}, %State{} = _state, %Data{} = data) do
    Logger.debug("received have from torrent, updating own bitfield")
    data = %Data{data | my_pieces: Bitfield.set_bit(data.my_pieces, index)}
    {:keep_state, data}
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
