# todo
# - [ ] uploads/seeding
# - [ ] configurable max download concurrency
# - [ ] configurable max upload concurrency
# - [x] verify local data on startup
# - [ ] API to force verify of local data
# - [ ] broadcast bitset to peer processes
# - [x] broadcast `have` to peer processes when we receive and checksum a piece
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
# - [ ] optimize metainfo so that each peer doesn't need a copy
#
# Peer -> TorrentState API

defmodule Bib.Torrent do
  @behaviour :gen_statem

  require Logger
  alias Bib.{Bencode, MetaInfo, Peer, Bitfield, PeerSupervisor, FileOps}

  defmodule State do
    defstruct []
  end

  defmodule Data do
    defstruct [
      :torrent_file,
      :download_location,
      :peer_id,
      :announce_response,
      :pieces,
      port: 6881 + :rand.uniform(2 ** 15 - 6881),
      max_uploads: 4,
      max_downloads: 4,
      active_downloads: 0,
      block_length: 2 ** 14
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
    Process.set_label("Torrent for #{args[:torrent_file]}")

    client_prefix = "-BK0001-"
    # id = :rand.bytes(13)
    id = "abcdefghijkl"
    peer_id = client_prefix <> id

    data = %Data{
      torrent_file: args[:torrent_file],
      download_location: args[:download_location],
      peer_id: peer_id
    }

    {:ok, :initializing, data, [{:next_event, :internal, :load_metainfo_file}]}
  end

  @impl :gen_statem
  def handle_event(:internal, :load_metainfo_file, :initializing, data) do
    metainfo_binary = File.read!(data.torrent_file)
    {:ok, decoded, <<>>} = Bencode.decode(metainfo_binary)
    :ok = MetaInfo.new(data.torrent_file, decoded)
    number_of_pieces = Enum.count(MetaInfo.pieces(data.torrent_file))
    data = %Data{data | pieces: <<0::size(number_of_pieces)>>}

    Logger.debug("Starting torrent for #{MetaInfo.name(data.torrent_file)}")

    Logger.debug(
      name: MetaInfo.name(data.torrent_file),
      piece_length: MetaInfo.piece_length(data.torrent_file),
      number_of_pieces: MetaInfo.number_of_pieces(data.torrent_file),
      length: MetaInfo.length(data.torrent_file),
      last_piece_length: MetaInfo.last_piece_length(data.torrent_file)
    )

    {:keep_state, data, [{:next_event, :internal, :verify_local_data}]}
  end

  def handle_event(:internal, :verify_local_data, :initializing, %Data{} = data) do
    Logger.debug("verifying local data for #{data.torrent_file}")

    download_filename = Path.join([data.download_location, MetaInfo.name(data.torrent_file)])

    if File.exists?(download_filename) do
      Logger.debug("#{download_filename} exists, verifying")

      pieces = FileOps.verify_local_data(data.torrent_file, download_filename)

      %{have: have, want: want} = Bitfield.counts(pieces)

      Logger.debug("have: #{have} pieces")
      Logger.debug("want: #{want} pieces")

      data = %Data{data | pieces: pieces}

      {:keep_state, data, [{:next_event, :internal, :announce}]}
    else
      Logger.debug(
        "#{download_filename} does not exist, creating and truncating to length #{MetaInfo.length(data.torrent_file)}"
      )

      FileOps.create_blank_file(download_filename, MetaInfo.length(data.torrent_file))

      {:keep_state, data, [{:next_event, :internal, :announce}]}
    end

    # data = %Data{data | pieces: <<>>}
    # TODO update with verified data
  end

  def handle_event(:internal, :announce, :initializing, data) do
    announce_url = MetaInfo.announce(data.torrent_file)
    info_hash = MetaInfo.info_hash(data.torrent_file)
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
          peer_id: data.peer_id,
          pieces: data.pieces,
          block_length: data.block_length
        })

      Logger.debug(inspect(conn))
    end

    {
      :next_state,
      %State{},
      data,
      [
        {{:timeout, :choke_timer}, :timer.seconds(10), :ok}
      ]
    }
  end

  def handle_event({:timeout, :choke_timer}, :ok, %State{} = _state, %Data{} = data) do
    # Logger.debug("choke timer")

    _peers = Bib.PeerSupervisor.peers(data.torrent_file)

    # 1. get peers from sup
    # 1.

    {
      :keep_state_and_data,
      [
        {{:timeout, :choke_timer}, :timer.seconds(10), :ok}
      ]
    }
  end

  def handle_event({:call, from}, {:have, index}, _state, %Data{} = data) do
    data = %Data{data | pieces: Bitfield.set_bit(data.pieces, index)}
    broadcast_async(data.torrent_file, {:have, index})

    %{have: have, want: want} = Bitfield.counts(data.pieces)

    if want == 0 && have == MetaInfo.number_of_pieces(data.torrent_file) do
      Logger.info("Complete!")
    end

    {:keep_state, data, [{:reply, from, :ok}]}
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
