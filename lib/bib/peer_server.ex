# https://wiki.theory.org/BitTorrentSpecification
#
# TORRENTS have PIECES which have BLOCKS
#
# todo
# - [x] tcp listener to spawn peers when remotes connect to us
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
# - [x] handle `request`
# - [x] handle `piece`
# - [ ] handle `cancel`
# - [x] send `interested` when we are interested
# - [x] send `not_interested` when we are not interested
# - [x] send `have` to torrent_state when we download/checksum piece
# - [x] interest timer
# - [x] keepalive timer
# - [x] figure out 16kB blocks for pieces
# - [ ] report download and upload to torrent state process
defmodule Bib.PeerServer do
  @moduledoc """
  This process handles the TCP connection and state for a single remote
  bittorrent peer for the given torrent.
  It is supervised by a `PeerSupervisor`.
  It is logically owned by a `Torrent` process,
  and communicates mainly with the `Torrent` process.
  It can be started from either the `Torrent` process (an outbound connection)
  or from the `Acceptor` process (an inbound connection).
  """

  @behaviour :gen_statem

  alias Bib.{
    TorrentServer,
    Bitfield,
    PeerSupervisor,
    MetaInfo,
    PiecesServer,
    FileOps,
    PeerProtocol
  }

  import Bib.Macros

  require Logger

  defmodule State do
    defstruct peer_is_choking_me: true,
              i_am_choking_peer: true,
              peer_is_interested_in_me: false,
              i_am_interested_in_peer: false
  end

  defmodule Data do
    # @enforce_keys [
    #   :torrent_file,
    #   :download_location,
    #   :peer_id,
    #   :remote_peer_address,
    #   :remote_peer_id,
    #   :my_pieces,
    #   :block_length
    # ]

    defstruct [
      :info_hash,
      :torrent_file,
      :download_location,
      :socket,
      :peer_id,
      :remote_peer_address,
      :remote_peer_port,
      :remote_peer_id,
      :peer_pieces,
      interest_interval: :timer.minutes(1),
      keepalive_interval: :timer.seconds(30),
      block_length: 2 ** 14
    ]
  end

  defmodule OutboundArgs do
    @enforce_keys [:info_hash, :remote_peer_address, :remote_peer_port]
    defstruct [
      :info_hash,
      :torrent_file,
      :download_location,
      :remote_peer_address,
      :remote_peer_port,
      :remote_peer_id,
      :peer_id,
      :pieces,
      :block_length
    ]
  end

  defmodule InboundArgs do
    @enforce_keys [
      :info_hash,
      :socket,
      :peer_id,
      :remote_peer_id,
      :remote_peer_address,
      :remote_peer_port
    ]
    defstruct [
      :info_hash,
      :socket,
      :peer_id,
      :download_location,
      :remote_peer_id,
      :remote_peer_address,
      :remote_peer_port
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

  @connect_timeout :timer.seconds(5)
  @receive_timeout :timer.seconds(5)
  @send_timeout :timer.seconds(5)

  @doc """
  start a peer process to connect to a remote peer
  """
  def connect(info_hash, %OutboundArgs{} = peer_args) when is_info_hash(info_hash) do
    PeerSupervisor.start_child(info_hash, peer_args)
  end

  @doc """
  start a peer process for a connection that was initiated by the remote peer
  """
  def accept_remote_peer_connection(info_hash, %InboundArgs{} = accept_args)
      when is_info_hash(info_hash) do
    PeerSupervisor.start_child(info_hash, accept_args)
  end

  def start_link(args) do
    :gen_statem.start_link(__MODULE__, args, [])
  end

  @doc """
  send a message to `peer` asynchronously, with no reply
  """
  def cast(peer, message) when is_pid(peer) do
    :gen_statem.cast(peer, message)
  end

  def choke(peer) when is_pid(peer) do
    :gen_statem.cast(peer, :choke)
  end

  def unchoke(peer) when is_pid(peer) do
    :gen_statem.cast(peer, :unchoke)
  end

  def handshake_peer(peer) when is_pid(peer) do
    :gen_statem.call(peer, :send_handshake)
  end

  def remote_peer_id(peer) when is_pid(peer) do
    :gen_statem.call(peer, :remote_peer_id)
  end

  @impl :gen_statem
  def init(%OutboundArgs{} = args) do
    state = %State{}

    data = %Data{
      info_hash: args.info_hash,
      torrent_file: args.torrent_file,
      download_location: args.download_location,
      remote_peer_address: args.remote_peer_address,
      remote_peer_port: args.remote_peer_port,
      remote_peer_id: args.remote_peer_id,
      peer_id: args.peer_id,
      peer_pieces: Bitfield.new_padded(MetaInfo.number_of_pieces(args.info_hash)),
      block_length: args.block_length
    }

    Logger.metadata(
      remote_peer_address: args.remote_peer_address,
      remote_peer_id: args.remote_peer_id
    )

    {:ok, state, data, [{:next_event, :internal, :connect_to_peer}]}
  end

  @impl :gen_statem
  def init(%InboundArgs{} = args) do
    Process.set_label(
      "Peer connection to #{inspect(args.remote_peer_address)}:#{inspect(args.remote_peer_port)}"
    )

    state = %State{}

    data = %Data{
      info_hash: args.info_hash,
      socket: args.socket,
      download_location: args.download_location,
      peer_id: args.peer_id,
      remote_peer_id: args.remote_peer_id,
      remote_peer_address: args.remote_peer_address,
      remote_peer_port: args.remote_peer_port,
      peer_pieces: Bitfield.new_padded(MetaInfo.number_of_pieces(args.info_hash))
    }

    {:ok, state, data,
     [
       {{:timeout, :keepalive_timer}, data.keepalive_interval, :ok}
     ]}
  end

  def handle_event(:internal, :send_handshake, %State{} = _state, %Data{} = data) do
    :ok = send_handshake(data.socket, data.info_hash, data.peer_id)
    Logger.debug("sent handshake")
    :ok = set_socket_opts(data.socket)
    {:keep_state, data, [{:next_event, :internal, :send_bitfield}]}
  end

  def handle_event(:internal, :send_bitfield, %State{} = _state, %Data{} = data) do
    {:ok, my_pieces} = PiecesServer.get(data.info_hash)
    bitfield_encoded = PeerProtocol.encode({:bitfield, my_pieces})
    :ok = :gen_tcp.send(data.socket, bitfield_encoded)
    Logger.debug("sent bitfield: #{inspect(bitfield_encoded)}")
    :keep_state_and_data
  end

  @impl :gen_statem
  def handle_event(:internal, :connect_to_peer, %State{} = _state, %Data{} = data) do
    case :gen_tcp.connect(
           data.remote_peer_address,
           data.remote_peer_port,
           [
             :binary,
             {:packet, 0},
             {:active, false},
             {:send_timeout, @send_timeout},
             {:send_timeout_close, true}
           ],
           @connect_timeout
         ) do
      {:ok, socket} ->
        Logger.debug("connected to #{inspect(data.remote_peer_address)}")
        Process.set_label("Peer connection to #{inspect(data.remote_peer_address)}")

        {:keep_state, %Data{data | socket: socket},
         [{:next_event, :internal, :send_and_receive_handshake}]}

      {:error, error} ->
        Logger.error(
          "could not connect to peer {#{inspect(data.remote_peer_address)}:#{inspect(data.remote_peer_port)}}, shutting down: #{inspect(error)}"
        )

        {:stop, :normal}
    end
  end

  def handle_event(:internal, :send_and_receive_handshake, %State{} = _state, %Data{} = data) do
    :ok = send_handshake(data.socket, data.info_hash, data.peer_id)

    Logger.debug("sent handshake to #{inspect(data.remote_peer_address)}")

    with {:ok, %{challenge_info_hash: challenge_info_hash, remote_peer_id: remote_peer_id}}
         when challenge_info_hash == data.info_hash and
                (remote_peer_id == data.remote_peer_id or is_nil(data.remote_peer_id)) <-
           receive_handshake(data.socket) do
      Logger.debug("HANDSHAKE SUCCESSFUL")

      :ok = set_socket_opts(data.socket)

      {:ok, my_pieces} = PiecesServer.get(data.info_hash)
      bitfield_encoded = PeerProtocol.encode({:bitfield, my_pieces})
      Logger.debug("sent bitfield: #{inspect(bitfield_encoded)}")
      :ok = :gen_tcp.send(data.socket, bitfield_encoded)

      {
        :keep_state_and_data,
        [
          {{:timeout, :interest_timer}, data.interest_interval, :ok},
          {{:timeout, :keepalive_timer}, data.keepalive_interval, :ok}
        ]
      }
    else
      {:error, :bad_handshake} ->
        Logger.debug("did not receive correct handshake, shutting down.")

        {:stop, :normal}

      {:error, e} ->
        Logger.debug("error receiving handshake, shutting down: #{inspect(e)}")
        {:stop, :normal}
    end
  end

  # def handle_event(:internal, :receive_handshake, %State{} = _state, %Data{} = data) do
  #   Logger.debug("waiting for handshake response")
  # end

  # keepalive
  def handle_event(:info, {:tcp, _socket, <<>>}, %State{} = _state, %Data{} = data) do
    :ok = set_socket_opts(data.socket)
    :keep_state_and_data
  end

  def handle_event(:info, {:tcp, _socket, packet}, %State{} = _state, %Data{} = _data) do
    peer_message = PeerProtocol.decode(packet)
    {:keep_state_and_data, [{:next_event, :internal, {:peer_message, peer_message}}]}
  end

  def handle_event(:info, {:tcp_closed, _socket}, %State{} = _state, %Data{} = _data) do
    Logger.debug("tcp closed, shutting down")
    {:stop, :normal}
  end

  def handle_event(:internal, {:peer_message, :choke}, %State{} = state, %Data{} = data) do
    Logger.debug("received choke")
    state = %State{state | peer_is_choking_me: true}
    :ok = set_socket_opts(data.socket)
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
    :ok = set_socket_opts(data.socket)
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
        %State{i_am_interested_in_peer: true, peer_is_choking_me: false} = _state,
        %Data{} = data
      ) do
    {:ok, my_pieces} = PiecesServer.get(data.info_hash)

    case Bitfield.random_wanted_piece(data.peer_pieces, my_pieces) do
      nil ->
        Logger.debug("no random wanted piece")
        :keep_state_and_data

      index ->
        Logger.debug("randomly downloading piece #{index}")

        blocks =
          MetaInfo.blocks_for_piece(data.info_hash, index, data.block_length)

        requests =
          Enum.map(blocks, fn {offset, length} -> {:request, index, offset, length} end)

        Enum.each(requests, fn request ->
          Logger.debug("requesting #{inspect(request)}")
          encoded = PeerProtocol.encode(request)
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
    :ok = set_socket_opts(data.socket)
    {:next_state, state, data}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :interested}, %State{} = state, %Data{} = data) do
    Logger.debug("received interested")
    state = %State{state | peer_is_interested_in_me: true}
    :ok = set_socket_opts(data.socket)
    {:next_state, state, data}
  end

  # TODO
  def handle_event(:internal, {:peer_message, :not_interested}, %State{} = state, %Data{} = data) do
    Logger.debug("received not_interested")
    state = %State{state | peer_is_interested_in_me: false}
    :ok = set_socket_opts(data.socket)
    {:next_state, state, data}
  end

  def handle_event(:internal, {:peer_message, {:have, index}}, _state, %Data{} = data) do
    Logger.debug("received have from peer for index #{index}, updating peer bitfield")
    data = %Data{data | peer_pieces: Bitfield.set_bit(data.peer_pieces, index)}
    Logger.debug("peer pieces: #{inspect(Bitfield.counts(data.peer_pieces))}")
    :ok = set_socket_opts(data.socket)
    {:keep_state, data}
  end

  def handle_event(
        :internal,
        {:peer_message, {:bitfield, bitfield}},
        %State{} = state,
        %Data{} = data
      ) do
    {:ok, my_pieces} = PiecesServer.get(data.info_hash)

    if byte_size(bitfield) == byte_size(Bitfield.pad_to_binary(my_pieces)) do
      Logger.debug("received good bitfield")
      data = %Data{data | peer_pieces: bitfield}

      if Bitfield.right_has_some_left_doesnt_have(my_pieces, data.peer_pieces) do
        Logger.debug("I am interested in peer due to bitfield")
        state = %State{state | i_am_interested_in_peer: true}
        :ok = set_socket_opts(data.socket)
        {:next_state, state, data}
      else
        Logger.debug("I am not interested in peer due to bitfield")
        :ok = set_socket_opts(data.socket)
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

    {:ok, block} =
      FileOps.read_block(
        data.info_hash,
        Path.join([data.download_location, MetaInfo.name(data.info_hash)]),
        index,
        begin,
        length
      )

    piece_message = PeerProtocol.encode({:piece, index, begin, block})

    :ok = :gen_tcp.send(data.socket, piece_message)

    Logger.debug("sent #{:erlang.iolist_size(block)} to peer for #{index}, #{begin}, #{length}")

    :ok = set_socket_opts(data.socket)

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
           data.info_hash,
           Path.join([data.download_location, MetaInfo.name(data.info_hash)]),
           index,
           begin,
           block
         ) do
      {:ok, true} ->
        Logger.debug(
          "received all of piece #{index} and hashes match, sending have to Torrent process, and downloading another piece"
        )

        :ok = TorrentServer.have(data.info_hash, index)

        :ok = PiecesServer.set(data.info_hash, index)

        :ok = set_socket_opts(data.socket)

        {:keep_state, data, [{:next_event, :internal, :request_blocks}]}

      {:ok, false} ->
        Logger.debug("piece #{index} did not match hash, piece is not complete yet")
        :ok = set_socket_opts(data.socket)
        {:keep_state, data}
    end
  end

  def handle_event(
        :internal,
        {:peer_message, {:cancel, index, begin, length}},
        %State{} = _state,
        %Data{} = data
      ) do
    Logger.debug("received cancel: #{index}, #{begin}, #{length}, not yet implemented")
    :ok = set_socket_opts(data.socket)
    {:keep_state, data}
  end

  # def handle_event(:internal, {:peer_message, peer_message}, _state, data) do
  #   Logger.warning("unhandled message: #{inspect(peer_message)}")
  #   :ok = :inet.setopts(data.socket, [:binary, {:packet, 4}, {:active, :once}])
  #   :keep_state_and_data
  # end

  def handle_event({:timeout, :interest_timer}, :ok, %State{} = state, %Data{} = data) do
    {:ok, my_pieces} = PiecesServer.get(data.info_hash)

    if Bitfield.right_has_some_left_doesnt_have(my_pieces, data.peer_pieces) do
      # interested
      Logger.debug("I am interested")

      encoded = PeerProtocol.encode(:interested)

      :ok = :gen_tcp.send(data.socket, encoded)

      Logger.debug("sent interested")

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

      encoded = PeerProtocol.encode(:not_interested)

      Logger.debug("sent not interested #{inspect(encoded)}")

      :ok = :gen_tcp.send(data.socket, encoded)

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
    :ok = :gen_tcp.send(data.socket, PeerProtocol.encode(:keepalive))

    Logger.debug("sent keepalive")

    {
      :keep_state_and_data,
      [{{:timeout, :keepalive_timer}, data.keepalive_interval, :ok}]
    }
  end

  def handle_event(:cast, :choke, %State{} = state, %Data{} = data) do
    choke = PeerProtocol.encode(:choke)

    :ok = :gen_tcp.send(data.socket, choke)

    {
      :next_state,
      %State{state | i_am_choking_peer: true},
      data
    }
  end

  def handle_event(:cast, :unchoke, %State{} = state, %Data{} = data) do
    unchoke = PeerProtocol.encode(:unchoke)

    :ok = :gen_tcp.send(data.socket, unchoke)

    {
      :next_state,
      %State{state | i_am_choking_peer: false},
      data
    }
  end

  def handle_event(:cast, {:have, index}, %State{} = _state, %Data{} = data) do
    Logger.debug("received have from torrent, updating own bitfield")
    encoded = PeerProtocol.encode({:have, index})
    :ok = :gen_tcp.send(data.socket, encoded)
    {:keep_state, data}
  end

  def handle_event({:call, from}, :send_handshake, %State{} = _state, %Data{} = _data) do
    {:keep_state_and_data,
     [
       {:reply, from, :ok},
       {:next_event, :internal, :send_handshake}
     ]}
  end

  def handle_event({:call, from}, :remote_peer_id, %State{} = _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, data.remote_peer_id}]}
  end

  def handle_event(:cast, :shutdown, %State{} = _state, %Data{} = _data) do
    :stop
  end

  @doc """
  Note: socket MUST be in passive mode.
  """
  def receive_handshake(socket) do
    with {_, {:ok, packet}} <-
           {:tcp, :gen_tcp.recv(socket, @handshake_length, @receive_timeout)},
         {_,
          <<19, "BitTorrent protocol",
            _reserved_bytes_length::binary-size(@reserved_bytes_length),
            challenge_info_hash::binary-size(@info_hash_length),
            remote_peer_id::binary-size(@peer_id_length)>>} <- {:handshake, packet} do
      {:ok, %{challenge_info_hash: challenge_info_hash, remote_peer_id: remote_peer_id}}
    else
      {:tcp, e} -> e
      {:handshake, p} -> {:error, :bad_handshake, p}
    end
  end

  defp send_handshake(socket, info_hash, peer_id)
       when is_info_hash(info_hash) and is_binary(peer_id) do
    :gen_tcp.send(socket, [
      19,
      <<"BitTorrent protocol">>,
      <<0, 0, 0, 0, 0, 0, 0, 0>>,
      info_hash,
      peer_id
    ])
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

  def set_socket_opts(socket) do
    :inet.setopts(socket, [
      :binary,
      {:packet, 4},
      {:active, :once},
      {:send_timeout, @send_timeout},
      {:send_timeout_close, true}
    ])
  end
end
