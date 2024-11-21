# todo
# - [ ] configurable max download concurrency
# - [ ] configurable max upload concurrency
# - [x] verify local data on startup
# - [ ] API to force verify of local data
# - [ ] broadcast bitset to peer processes
# - [ ] broadcast `have` to peer processes when we receive and checksum a piece
# - [ ] generate peer id on startup
# - [ ] track global uploaded amount (receive upload reports from peers)
# - [ ] track global downloaded amount (progress from completed pieces)
# - [ ] announce start/stopped/etc to tracker
# - [ ] announce uploaded to tracker
# - [ ] announce downloaded to tracker
# - [ ] announce timer
# - [ ] timers to choke/unchoke peers
# - [ ] timers to try to request pieces from different peers
# - [ ] track individual peer upload/download
#
# Peer -> TorrentState API

defmodule Bib.TorrentState do
  @behaviour :gen_statem

  require Logger
  alias Bib.PeerSupervisor
  alias Bib.{Bencode, MetaInfo, Peer, Bitfield}

  defmodule State do
    defstruct []
  end

  defmodule Data do
    defstruct [
      :metainfo,
      :torrent_file,
      :download_location,
      :peer_id,
      :port,
      :announce_response,
      :connected_peers,
      :pieces
    ]
  end

  def start_link(args) do
    :gen_statem.start_link(name(args[:torrent_file]), __MODULE__, args, [])
  end

  @doc """
  send a message to all peers, asynchronously, with no reply
  """
  def broadcast_async(torrent_file, message) do
    peers = PeerSupervisor.peers(torrent_file)

    Enum.each(peers, fn peer ->
      Peer.cast(peer, message)
    end)
  end

  def have(torrent_file, index) do
    torrent_file
    |> name()
    |> :gen_statem.call({:have, index})
  end

  @impl :gen_statem
  def init(args) do
    Process.set_label("TorrentState for #{args[:torrent_file]}")

    client_prefix = "-BR001-"
    # id = :rand.bytes(13)
    id = "abcdefghijklm"
    peer_id = client_prefix <> id

    data = %Data{
      torrent_file: args[:torrent_file],
      download_location: args[:download_location],
      peer_id: peer_id,
      port: 6881
    }

    {:ok, :initializing, data, [{:next_event, :internal, :load_metainfo_file}]}
  end

  @impl :gen_statem
  def handle_event(:internal, :load_metainfo_file, :initializing, data) do
    metainfo_binary = File.read!(data.torrent_file)
    {:ok, decoded, <<>>} = Bencode.decode(metainfo_binary)
    metainfo = MetaInfo.new(decoded)
    number_of_pieces = Enum.count(MetaInfo.pieces(metainfo))
    data = %Data{data | metainfo: metainfo, pieces: <<0::size(number_of_pieces)>>}
    {:keep_state, data, [{:next_event, :internal, :verify_local_data}]}
  end

  def handle_event(:internal, :verify_local_data, :initializing, %Data{} = data) do
    Logger.debug("verifying local data for #{data.torrent_file}")

    download_filename = Path.join([data.download_location, MetaInfo.name(data.metainfo)])

    if File.exists?(download_filename) do
      {:ok, fd} = :file.open(download_filename, [:read, :raw])

      Logger.debug("#{download_filename} exists, verifying")

      piece_hashes = MetaInfo.pieces(data.metainfo)
      number_of_pieces = bit_size(data.pieces)
      normal_piece_length = MetaInfo.piece_length(data.metainfo)
      last_piece_length = MetaInfo.last_piece_length(data.metainfo)

      pieces =
        piece_hashes
        |> Stream.with_index()
        |> Enum.reduce(data.pieces, fn {piece_hash, index}, pieces ->
          offset = index * normal_piece_length

          actual_piece_length =
            if index == number_of_pieces - 1 do
              last_piece_length
            else
              normal_piece_length
            end

          Logger.debug("reading piece {#{index}, #{offset}, #{actual_piece_length}}")

          {:ok, piece} = :file.pread(fd, offset, actual_piece_length)

          if :crypto.hash(:sha, piece) == piece_hash do
            Bitfield.set_bit(pieces, index)
          else
            pieces
          end
        end)

      have = Bitfield.population_count(pieces)

      Logger.debug("have: #{have} pieces")
      Logger.debug("want: #{number_of_pieces - have} pieces")

      data = %Data{data | pieces: pieces}

      {:keep_state, data, [{:next_event, :internal, :announce}]}
    else
      Logger.debug(
        "#{download_filename} does not exist, creating and truncating to length #{MetaInfo.length(data.metainfo)}"
      )

      {:ok, fd} =
        :file.open(download_filename, [
          :write,
          :raw
        ])

      {:ok, _} = :file.position(fd, MetaInfo.length(data.metainfo))
      :ok = :file.truncate(fd)

      {:keep_state, data, [{:next_event, :internal, :announce}]}
    end

    # data = %Data{data | pieces: <<>>}
    # TODO update with verified data
  end

  def handle_event(:internal, :announce, :initializing, data) do
    announce_url = MetaInfo.announce(data.metainfo)
    info_hash = MetaInfo.info_hash(data.metainfo)
    peer_id = data.peer_id
    port = data.port

    with {_, {:ok, response}} <-
           {:announce_get,
            Req.get(announce_url,
              params: [
                info_hash: info_hash,
                peer_id: peer_id,
                port: port,
                uploaded: 0,
                downloaded: 0,
                event: "started"
              ]
            )},
         {_, {:ok, decoded_announce_response, <<>>}} <-
           {:bencode_decode, Bencode.decode(response.body)} do
      data = %Data{data | announce_response: decoded_announce_response}
      {:next_state, :started, data, [{:next_event, :internal, :connect_to_peers}]}
    else
      e ->
        raise e
    end
  end

  def handle_event(:internal, :connect_to_peers, :started, %Data{} = data) do
    available_peers =
      data.announce_response
      |> Map.fetch!("peers")
      |> Enum.filter(fn %{"peer id" => peer_id} ->
        peer_id != data.peer_id
      end)

    Logger.debug(inspect(available_peers))

    for %{"ip" => ip, "port" => port, "peer id" => remote_peer_id} <- available_peers do
      conn =
        Peer.connect(data.torrent_file, %Peer.Args{
          torrent_file: data.torrent_file,
          download_location: data.download_location,
          remote_peer_address: {ip, port},
          remote_peer_id: remote_peer_id,
          info_hash: MetaInfo.info_hash(data.metainfo),
          peer_id: data.peer_id,
          pieces: data.pieces,
          piece_hashes: MetaInfo.pieces(data.metainfo),
          piece_length: MetaInfo.piece_length(data.metainfo),
          last_piece_length: MetaInfo.last_piece_length(data.metainfo)
        })

      Logger.debug(inspect(conn))
    end

    :keep_state_and_data
  end

  def handle_event({:call, _from}, {:have, index}, _state, data) do
    data = %Data{data | pieces: Bitfield.set_bit(data.pieces, index)}
    broadcast_async(data.torrent_file, {:have, index})
    {:keep_state, data}
  end

  def name(torrent_file) do
    {:via, Registry, {Bib.Registry, {__MODULE__, torrent_file}}}
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
      restart: :permanent
    }
  end
end
