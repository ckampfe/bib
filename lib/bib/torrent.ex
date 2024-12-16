# todo
# - [x] uploads/seeding
# - [ ] configurable max download concurrency
# - [ ] configurable max upload concurrency
# - [x] verify local data on startup
# - [x] API to force verify of local data
# - [x] broadcast bitset to peer processes
# - [x] broadcast `have` to peer processes when we receive and checksum a piece
# - [x] generate peer id on startup
# - [ ] track global uploaded amount (receive upload reports from peers)
# - [ ] track global downloaded amount (progress from completed pieces)
# - [x] announce start/stopped/etc to tracker
# - [x] announce left to tracker
# - [ ] announce uploaded to tracker
# - [ ] announce downloaded to tracker
# - [x] announce timer
# - [x] timers to choke/unchoke peers
# - [ ] timers to try to request pieces from different peers
# - [ ] track individual peer upload/download
# - [x] optimize metainfo so that each peer doesn't need a copy
# - [ ] store a persistent list of torrents to load on boot
# - [x] ability to get time until next announce
#
# Peer -> TorrentState API

defmodule Bib.Torrent do
  @behaviour :gen_statem

  require Logger
  alias Bib.{Bencode, MetaInfo, Peer, Bitfield, PeerSupervisor, FileOps}
  import Bib.Macros

  defmodule State do
    defstruct state: :initializing
  end

  defmodule Data do
    defstruct [
      :info_hash,
      :torrent_file,
      :download_location,
      :peer_id,
      :announce_response,
      :pieces,
      :port,
      :last_announce_at,
      uploaded: 0,
      downloaded: 0,
      max_uploads: 4,
      max_downloads: 4,
      active_downloads: 0,
      block_length: 2 ** 14
    ]
  end

  #############################################################################
  # START PUBLIC API
  #############################################################################

  def start_link(args) do
    :gen_statem.start_link(name(args.info_hash), __MODULE__, args, timeout: :timer.seconds(5))
  end

  @doc """
  send a message to all peers, asynchronously, with no reply
  """
  def send_to_all_peers_async(info_hash, message) when is_info_hash(info_hash) do
    peers = PeerSupervisor.peers(info_hash)
    send_to_peers_async(peers, message)
  end

  def send_to_peers_async(peers, message) when is_list(peers) do
    Enum.each(peers, fn peer ->
      Peer.cast(peer, message)
    end)
  end

  def have(info_hash, index) when is_info_hash(info_hash) do
    info_hash
    |> name()
    |> :gen_statem.call({:have, index})
  end

  def get_peer_id(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :get_peer_id)
  end

  def get_pieces(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :get_pieces)
  end

  def get_download_location(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :get_download_location)
  end

  def pause(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :pause)
  end

  def resume(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :resume)
  end

  def accepting_connections?(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :accepting_connections?)
  end

  def time_until_announce(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :time_until_announce)
  end

  def verify_local_data(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :verify_local_data)
  end

  #############################################################################
  # END PUBLIC API
  #############################################################################

  @impl :gen_statem
  def init(args) do
    Process.set_label("Torrent for #{Path.basename(args[:torrent_file])}")

    state = %State{}

    client_prefix = "-BK0001-"
    # random_id = :rand.bytes(20 - byte_size(client_prefix))
    random_id = "ABCDEFGHIJKL"
    peer_id = client_prefix <> random_id

    data = %Data{
      info_hash: args.info_hash,
      torrent_file: args.torrent_file,
      download_location: args.download_location,
      peer_id: peer_id,
      port: args.port
    }

    {:ok, state, data, [{:next_event, :internal, :load_metainfo_file}]}
  end

  # def handle_event(:enter, _oldstate, %State{state: :initializing}, data) do
  #   Logger.debug("initializing")
  #   {:keep_state_and_data, [{:next_event, :internal, :load_metainfo_file}]}
  # end

  @impl :gen_statem
  def handle_event(:internal, :load_metainfo_file, %State{} = _state, %Data{} = data) do
    number_of_pieces = MetaInfo.number_of_pieces(data.info_hash)
    data = %Data{data | pieces: <<0::size(number_of_pieces)>>}

    Logger.debug("Starting torrent for #{MetaInfo.name(data.info_hash)}")

    Logger.debug(
      name: MetaInfo.name(data.info_hash),
      piece_length: MetaInfo.piece_length(data.info_hash),
      number_of_pieces: MetaInfo.number_of_pieces(data.info_hash),
      length: MetaInfo.length(data.info_hash),
      last_piece_length: MetaInfo.last_piece_length(data.info_hash)
    )

    {:keep_state, data, [{:next_event, :internal, :verify_local_data}]}
  end

  def handle_event(:internal, :verify_local_data, %State{} = _state, %Data{} = data) do
    Logger.debug("verifying local data for #{data.torrent_file}")

    download_filename = Path.join([data.download_location, MetaInfo.name(data.info_hash)])

    if File.exists?(download_filename) do
      Logger.debug("#{download_filename} exists, verifying")

      pieces = FileOps.verify_local_data(data.info_hash, download_filename)

      data = %Data{data | pieces: pieces}

      {:keep_state, data, [{:next_event, :internal, :announce_started}]}
    else
      Logger.debug(
        "#{download_filename} does not exist, creating and truncating to length #{MetaInfo.length(data.info_hash)}"
      )

      _ = FileOps.create_blank_file(download_filename, MetaInfo.length(data.info_hash))

      {:keep_state, data, [{:next_event, :internal, :announce_started}]}
    end

    # data = %Data{data | pieces: <<>>}
    # TODO update with verified data
  end

  def handle_event(:internal, :announce_started, %State{} = _state, %Data{} = data) do
    %{have: have, want: want} = Bitfield.counts(data.pieces)
    Logger.debug("have: #{have} pieces")
    Logger.debug("want: #{want} pieces")

    left = MetaInfo.left(data.info_hash, data.pieces)
    Logger.debug(left: left)

    with {_, {:ok, response}} <-
           {:announce_get, announce(data, :started)},
         {_, {:ok, decoded_announce_response, <<>>}} <-
           {:bencode_decode, Bencode.decode(response.body)} do
      data = %Data{
        data
        | announce_response: decoded_announce_response,
          last_announce_at: Time.utc_now()
      }

      Logger.debug(port: data.port)
      Logger.debug("#{inspect(decoded_announce_response)}")

      Logger.debug(
        "announcing again in #{Map.fetch!(data.announce_response, "interval")} seconds"
      )

      timers =
        [
          {{:timeout, :announce_timer},
           :timer.seconds(Map.fetch!(data.announce_response, "interval")), :ok},
          {{:timeout, :choke_timer}, :timer.seconds(10), :ok}
        ]

      actions =
        if left > 0 do
          timers ++ [{:next_event, :internal, :connect_to_peers}]
        else
          Logger.debug("we have all pieces at startup, not connecting to other peers")
          timers
        end

      {:next_state, %State{state: :started}, data, actions}
    else
      e ->
        raise e
    end
  end

  def handle_event(:internal, :connect_to_peers, %State{}, %Data{} = data) do
    available_peers =
      data.announce_response
      |> Map.fetch!("peers")
      |> Enum.filter(fn %{"peer id" => peer_id} ->
        peer_id != data.peer_id
      end)

    Logger.debug(inspect(available_peers))

    for %{"ip" => ip, "port" => port, "peer id" => remote_peer_id} <- available_peers do
      conn =
        Peer.connect(data.info_hash, %Peer.Args{
          info_hash: data.info_hash,
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
      []
    }
  end

  # TODO:
  # this is very bad...
  # do the actual algorithm here
  # to choke unchoke based on upload/download statistics
  # and opportunistic unchoke to random peer
  def handle_event({:timeout, :choke_timer}, :ok, %State{} = _state, %Data{} = data) do
    Logger.debug("choke timer")

    peers = Bib.PeerSupervisor.peers(data.info_hash)

    if !Enum.empty?(peers) do
      send_to_all_peers_async(data.info_hash, :choke)
      peers_to_unchoke = n_random(peers, data.max_uploads)
      Logger.debug("unchoking #{inspect(peers_to_unchoke)}")
      send_to_peers_async(peers_to_unchoke, :unchoke)
    end

    # TODO just store the pids of the currently choked pids so we avoid
    # rapidly choking/unchoking them in the case where there are less
    # peers than available upload slots

    {
      :keep_state_and_data,
      [
        {{:timeout, :choke_timer}, :timer.seconds(10), :ok}
      ]
    }
  end

  def handle_event({:timeout, :announce_timer}, :ok, %State{} = _state, %Data{} = data) do
    Logger.debug("regular announce timer")

    with {_, {:ok, response}} <-
           {:announce_get, announce(data)},
         {_, {:ok, decoded_announce_response, <<>>}} <-
           {:bencode_decode, Bencode.decode(response.body)} do
      data = %Data{
        data
        | announce_response: decoded_announce_response,
          last_announce_at: Time.utc_now()
      }

      Logger.debug(
        "announcing again in #{Map.fetch!(data.announce_response, "interval")} seconds"
      )

      {
        :keep_state,
        data,
        [
          {{:timeout, :announce_timer},
           :timer.seconds(Map.fetch!(data.announce_response, "interval")), :ok}
        ]
      }
    end
  end

  def handle_event({:call, from}, {:have, index}, _state, %Data{} = data) do
    data = %Data{data | pieces: Bitfield.set_bit(data.pieces, index)}
    send_to_all_peers_async(data.info_hash, {:have, index})

    %{have: have, want: want} = Bitfield.counts(data.pieces)

    if want == 0 && have == MetaInfo.number_of_pieces(data.info_hash) do
      Logger.info("Complete!")

      with {_, {:ok, response}} <-
             {:announce_get, announce(data, :completed)},
           {_, {:ok, decoded_announce_response, <<>>}} <-
             {:bencode_decode, Bencode.decode(response.body)} do
        data = %Data{
          data
          | announce_response: decoded_announce_response,
            last_announce_at: Time.utc_now()
        }

        # {:next_state, :started, data, [{:next_event, :internal, :connect_to_peers}]}
        {:keep_state, data, [{:reply, from, :ok}]}
      else
        error ->
          Logger.warning("error attempting to announce completion: #{inspect(error)}")
          {:keep_state, data, [{:reply, from, :ok}]}
      end
    else
      {:keep_state, data, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, :get_peer_id, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.peer_id}}]}
  end

  def handle_event({:call, from}, :get_pieces, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.pieces}}]}
  end

  def handle_event({:call, from}, :get_download_location, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.download_location}}]}
  end

  def handle_event({:call, from}, :pause, %State{} = state, %Data{} = data) do
    data =
      with {_, {:ok, response}} <-
             {:announce_get, announce(data, :stopped)},
           {_, {:ok, decoded_announce_response, <<>>}} <-
             {:bencode_decode, Bencode.decode(response.body)} do
        %Data{
          data
          | announce_response: decoded_announce_response,
            last_announce_at: Time.utc_now()
        }
      else
        e ->
          Logger.warning("error attempting to announce on pause: #{inspect(e)}")
          %Data{data | last_announce_at: Time.utc_now()}
      end

    # TODO
    # - shutdown currently connected peers
    # - some way to not accept new peer connections...need to set state to :paused

    state = %State{state | state: :paused}

    {
      :next_state,
      state,
      data,
      [
        {:reply, from, :ok},
        {{:timeout, :announce_timer}, :infinity, :ok},
        {{:timeout, :choke_timer}, :infinity, :ok}
      ]
    }
  end

  def handle_event({:call, from}, :resume, _state, %Data{} = _data) do
    {:keep_state_and_data, [{:reply, from, :ok}, {:next_event, :internal, :announce_started}]}
  end

  def handle_event({:call, from}, :accepting_connections?, %State{state: state}, %Data{} = _data) do
    reply = state in [:started, :finished]
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, :time_until_announce, %State{} = _state, %Data{} = data) do
    reply =
      if data.last_announce_at do
        {:ok,
         Time.diff(
           Time.add(data.last_announce_at, Map.fetch!(data.announce_response, "interval")),
           Time.utc_now()
         )}
      else
        {:error, :unknown}
      end

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, :verify_local_data, %State{} = _state, %Data{} = data) do
    download_filename = Path.join([data.download_location, MetaInfo.name(data.info_hash)])

    data =
      if File.exists?(download_filename) do
        Logger.debug("#{download_filename} exists, verifying")
        pieces = FileOps.verify_local_data(data.info_hash, download_filename)
        %Data{data | pieces: pieces}
      else
        Logger.debug("#{download_filename} does not exist")
        number_of_pieces = MetaInfo.number_of_pieces(data.info_hash)
        %Data{data | pieces: <<0::size(number_of_pieces)>>}
      end

    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def name(info_hash) when is_info_hash(info_hash) do
    {:via, Registry, {Bib.Registry, {__MODULE__, info_hash}}}
  end

  @doc """
  https://wiki.theory.org/BitTorrentSpecification#Tracker_Request_Parameters
  """
  def announce(%Data{} = data, event \\ nil)
      when event in [:started, :completed, :stopped, nil] do
    left = MetaInfo.left(data.info_hash, data.pieces)
    tracker_url = MetaInfo.announce(data.info_hash)
    event = Atom.to_string(event)

    Req.get(tracker_url,
      params: [
        info_hash: data.info_hash,
        peer_id: data.peer_id,
        port: data.port,
        left: left,
        uploaded: data.uploaded,
        downloaded: data.downloaded,
        event: event
      ]
    )
  end

  @impl :gen_statem
  def callback_mode() do
    # TODO investigate doing actual state transitions rather than ad-hoc
    # [:handle_event_function, :state_enter]
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

  defp n_random(collection, n) do
    n_random(collection, n, [])
  end

  defp n_random(collection, n, selections)

  defp n_random(collection, _n, selections) when length(selections) == length(collection) do
    Enum.map(selections, fn i -> Enum.at(collection, i) end)
  end

  defp n_random(collection, n, selections) when length(selections) < n do
    random_index = Enum.random(0..(Enum.count(collection) - 1))

    if random_index not in selections do
      n_random(collection, n, [random_index | selections])
    else
      n_random(collection, n, selections)
    end
  end

  defp n_random(collection, _n, selections) do
    Enum.map(selections, fn i ->
      Enum.at(collection, i)
    end)
  end
end
