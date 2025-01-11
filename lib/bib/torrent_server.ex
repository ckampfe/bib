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
# - [x] handle compact peer tracker responses
# - [ ] request compact peer tracker response by default
# - [ ] ability to download multiple files
#
# Peer -> TorrentState API

defmodule Bib.TorrentServer do
  @moduledoc """
  This process is the main location for a single torrent's state.
  Each torrent gets one of these processes.
  It communicates with `Peer` processes, which handle the TCP connections to remote peers.
  It deals with tracker communication.
  It's metainfo data (from the .torrent file) is stored in :persistent_term, see `name/1`
  """

  @behaviour :gen_statem

  require Logger
  alias Bib.{Bencode, MetaInfo, PeerServer, PeerSupervisor, FileOps, PiecesServer}
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
      :port,
      :last_announce_at,
      :announce_ref,
      announce_response: %{},
      announce_interval: 120,
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

  # TODO: use pg for this?
  # https://www.erlang.org/doc/apps/kernel/pg.ht
  def send_to_peers_async(peers, message) when is_list(peers) do
    Enum.each(peers, fn peer ->
      PeerServer.cast(peer, message)
    end)
  end

  def have(info_hash, index) when is_info_hash(info_hash) do
    info_hash
    |> name()
    |> :gen_statem.call({:have, index})
  end

  def get_metadata(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :get_metadata)
  end

  def get_peer_id(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :get_peer_id)
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

  def get_peers(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :get_peers)
  end

  def force_announce(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :force_announce)
  end

  #############################################################################
  # END PUBLIC API
  #############################################################################

  @impl :gen_statem
  def init(args) do
    Process.set_label("TorrentServer for #{Path.basename(args[:torrent_file])}")

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

    {
      :ok,
      state,
      data,
      [
        {:next_event, :internal, :load_metainfo_file}
      ]
    }
  end

  # def handle_event(:enter, _oldstate, %State{state: :initializing}, data) do
  #   Logger.debug("initializing")
  #   {:keep_state_and_data, [{:next_event, :internal, :load_metainfo_file}]}
  # end

  @impl :gen_statem
  def handle_event(:internal, :load_metainfo_file, %State{} = _state, %Data{} = data) do
    number_of_pieces = MetaInfo.number_of_pieces(data.info_hash)
    PiecesServer.insert(data.info_hash, <<0::size(number_of_pieces)>>)

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

  # TODO actually do not set download timer here
  # in the case that we have all pieces and are seeding
  def handle_event(:internal, :verify_local_data, %State{} = _state, %Data{} = data) do
    Logger.debug("verifying local data for #{data.torrent_file}")

    download_filename = Path.join([data.download_location, MetaInfo.name(data.info_hash)])

    if File.exists?(download_filename) do
      Logger.debug("#{download_filename} exists, verifying")

      pieces = FileOps.verify_local_data(data.info_hash, download_filename)

      :ok = PiecesServer.insert(data.info_hash, pieces)

      {
        :next_state,
        %State{state: :started},
        data,
        [
          {{:timeout, :choke_timer}, :timer.seconds(10), :ok},
          {{:timeout, :download_timer}, :timer.seconds(5), :ok},
          {{:timeout, :announce_timer}, :timer.seconds(data.announce_interval), :ok},
          {:next_event, :internal, :announce}
        ]
      }
    else
      Logger.debug(
        "#{download_filename} does not exist, creating and truncating to length #{MetaInfo.length(data.info_hash)}"
      )

      _ = FileOps.create_blank_file(download_filename, MetaInfo.length(data.info_hash))

      {
        :next_state,
        %State{state: :started},
        data,
        [
          {{:timeout, :choke_timer}, :timer.seconds(10), :ok},
          {{:timeout, :download_timer}, :timer.seconds(5), :ok},
          {{:timeout, :announce_timer}, :timer.seconds(data.announce_interval), :ok},
          {:next_event, :internal, :announce}
        ]
      }
    end

    # data = %Data{data | pieces: <<>>}
    # TODO update with verified data
  end

  # handle the response from the announce request
  def handle_event(
        :info,
        {ref, response},
        %State{} = _state,
        %Data{announce_ref: ref} = data
      ) do
    Process.demonitor(ref, [:flush])

    data =
      case response do
        {:ok, response} ->
          %Data{
            data
            | announce_response: response.body,
              last_announce_at: Time.utc_now(),
              announce_interval: Map.fetch!(response.body, "interval")
          }

        {:announce_get, {:error, e}} ->
          Logger.debug("got network error when announcing to tracker: #{inspect(e)}")
          data

        {:bencode_decode, e} ->
          Logger.debug("got bencode error when announcing to tracker: #{inspect(e)}")
          data
      end

    data = %Data{data | announce_ref: nil}

    {
      :keep_state,
      data
    }
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        %State{},
        %Data{announce_ref: ref} = data
      ) do
    data = %Data{data | announce_ref: nil}
    {:keep_state, data}
  end

  def handle_event({:timeout, :download_timer}, :ok, %State{state: :completed}, %Data{}) do
    {:keep_state_and_data,
     [
       {{:timeout, :download_timer}, :infinity, :ok}
     ]}
  end

  def handle_event({:timeout, :download_timer}, :ok, %State{} = state, %Data{} = data) do
    # TODO actually do stuff where we connect to peers and download!
    Logger.debug("download timer. state is #{inspect(state)}")

    if peers = Map.get(data.announce_response, "peers") do
      Logger.debug("connecting to peers because we have some")

      {:ok, pieces} = PiecesServer.get(data.info_hash)

      for %{"ip" => remote_peer_address, "port" => remote_peer_port, "peer id" => remote_peer_id} <-
            peers do
        # TODO:
        # figure out how to not connect to already connected peers
        # this way is kinda hacky and won't work if the remote doesn't
        # have a peer id due to the tracker returning compact peers.
        # use ip and port? idk

        peers = PeerSupervisor.peers(data.info_hash)

        peer_ids =
          peers
          |> Enum.map(fn pid ->
            PeerServer.remote_peer_id(pid)
          end)
          |> Enum.into(MapSet.new())

        if !MapSet.member?(peer_ids, remote_peer_id) do
          PeerServer.connect(data.info_hash, %PeerServer.OutboundArgs{
            info_hash: data.info_hash,
            torrent_file: data.torrent_file,
            download_location: data.download_location,
            remote_peer_address: remote_peer_address,
            remote_peer_port: remote_peer_port,
            remote_peer_id: remote_peer_id,
            peer_id: data.peer_id,
            pieces: pieces,
            block_length: data.block_length
          })
        end
      end
    else
      Logger.debug("not connecting to peers because we don't have any")
    end

    {:keep_state_and_data, [{{:timeout, :download_timer}, :timer.seconds(5), :ok}]}
  end

  # def handle_event(:internal, :connect_to_peers, %State{}, %Data{} = data) do
  #   peers = Map.fetch!(data.announce_response, "peers")

  #   for %{"ip" => remote_peer_address, "port" => remote_peer_port, "peer id" => remote_peer_id} <-
  #         peers do
  #     Peer.connect(data.info_hash, %Peer.OutboundArgs{
  #       info_hash: data.info_hash,
  #       torrent_file: data.torrent_file,
  #       download_location: data.download_location,
  #       remote_peer_address: remote_peer_address,
  #       remote_peer_port: remote_peer_port,
  #       remote_peer_id: remote_peer_id,
  #       peer_id: data.peer_id,
  #       pieces: data.pieces,
  #       block_length: data.block_length
  #     })
  #   end

  #   {:next_state, %State{}, data, []}
  # end

  # if there is a current announce task in flight,
  # do nothing.
  def handle_event(
        :internal,
        :announce,
        %State{},
        %Data{announce_ref: announce_ref} = data
      )
      when not is_nil(announce_ref) do
    {
      :keep_state,
      data,
      []
    }
  end

  # if there is no current announce task in flight,
  # we are good to go, schedule an announce in a task
  def handle_event(
        :internal,
        :announce,
        %State{} = state,
        %Data{announce_ref: announce_ref} = data
      )
      when is_nil(announce_ref) do
    announce_task =
      Task.Supervisor.async_nolink(Bib.TaskSupervisor, __MODULE__, :announce, [data, state.state])

    data = %Data{data | announce_ref: announce_task.ref}

    {
      :keep_state,
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
    {
      :keep_state,
      data,
      [
        {:next_event, :internal, :announce},
        {{:timeout, :announce_timer}, :timer.seconds(data.announce_interval), :ok}
      ]
    }
  end

  def handle_event({:call, from}, :get_metadata, state, %Data{} = data) do
    total_pieces = MetaInfo.number_of_pieces(data.info_hash)
    {:ok, counts} = PiecesServer.counts(data.info_hash)
    {:ok, pieces} = PiecesServer.get(data.info_hash)

    metadata = %{
      info_hash: data.info_hash,
      name: MetaInfo.name(data.info_hash),
      pieces: pieces,
      progress: counts.have / total_pieces * 100,
      have: counts.have,
      want: counts.want,
      state: Atom.to_string(state.state),
      seeders: 0,
      leachers: 0,
      download_speed: 0,
      upload_speed: 0
    }

    {:keep_state, data, [{:reply, from, {:ok, metadata}}]}
  end

  def handle_event({:call, from}, {:have, index}, _state, %Data{} = data) do
    send_to_all_peers_async(data.info_hash, {:have, index})

    {:ok, %{have: have, want: want}} = PiecesServer.counts(data.info_hash)

    if want == 0 && have == MetaInfo.number_of_pieces(data.info_hash) do
      Logger.info("Complete!")

      # TODO use the Task for this
      with {:ok, response} <- announce(data, :completed) do
        data = %Data{
          data
          | announce_response: response.body,
            last_announce_at: Time.utc_now()
        }

        {:next_state, %State{state: :completed}, data, [{:reply, from, :ok}]}
      else
        {:announce_get, {:error, error}} ->
          Logger.warning("error attempting to announce completion: #{inspect(error)}")
          {:keep_state, data, [{:reply, from, :ok}]}

        {:bencode_decode, {:error, error, position} = e} ->
          Logger.debug(
            "bencode decoding error when announcing `started`: #{error} at position #{position}"
          )

          {:stop, inspect(e)}
      end
    else
      {:keep_state, data, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, :get_peer_id, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.peer_id}}]}
  end

  def handle_event({:call, from}, :get_download_location, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.download_location}}]}
  end

  def handle_event({:call, from}, :pause, %State{}, %Data{} = data) do
    # TODO
    # - [x] shutdown currently connected peers
    send_to_all_peers_async(data.info_hash, :shutdown)
    # - [_] some way to not accept new peer connections...need to set state to :paused

    state = %State{state: :stopped}

    {
      :next_state,
      state,
      data,
      [
        {:reply, from, :ok},
        {{:timeout, :choke_timer}, :infinity, :ok},
        {{:timeout, :download_timer}, :infinity, :ok},
        {{:timeout, :announce_timer}, :infinity, :ok},
        {:next_event, :internal, :announce}
      ]
    }
  end

  def handle_event({:call, from}, :resume, _state, %Data{} = data) do
    {
      :next_state,
      %State{state: :started},
      data,
      [
        {:reply, from, :ok},
        {{:timeout, :choke_timer}, :timer.seconds(10), :ok},
        {{:timeout, :download_timer}, :timer.seconds(5), :ok},
        {{:timeout, :announce_timer}, :timer.seconds(data.announce_interval), :ok},
        {:next_event, :internal, :announce}
      ]
    }
  end

  def handle_event({:call, from}, :accepting_connections?, %State{state: state}, %Data{} = _data) do
    reply = state in [:initializing, :started, :finished]
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

    if File.exists?(download_filename) do
      Logger.debug("#{download_filename} exists, verifying")
      pieces = FileOps.verify_local_data(data.info_hash, download_filename)
      PiecesServer.insert(data.info_hash, pieces)
    else
      Logger.debug("#{download_filename} does not exist")
      number_of_pieces = MetaInfo.number_of_pieces(data.info_hash)
      PiecesServer.insert(data.info_hash, <<0::size(number_of_pieces)>>)
    end

    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :get_peers, %State{} = _state, %Data{} = data) do
    announce_response = Map.get(data, :announce_response, %{})
    peers = Map.get(announce_response, "peers", [])

    {:keep_state_and_data, [{:reply, from, {:ok, peers}}]}
  end

  def handle_event({:call, from}, :force_announce, %State{} = _state, %Data{} = data) do
    Logger.debug("force announce")
    # TODO either here or somewhere else decide whether to
    # actually announce based on when the last announce was,
    # to prevent spamming the tracker

    {
      :keep_state,
      data,
      [
        {:reply, from, :ok},
        {:next_event, :internal, :announce}
      ]
    }
  end

  def name(info_hash) when is_info_hash(info_hash) do
    {:via, Registry, {Bib.Registry, {__MODULE__, info_hash}}}
  end

  # https://wiki.theory.org/BitTorrentSpecification#Tracker_Request_Parameters
  def announce(%Data{} = data, event \\ nil)
      when event in [:started, :completed, :stopped, nil] do
    Logger.debug("Announcing...")
    {:ok, pieces} = PiecesServer.get(data.info_hash)
    left = MetaInfo.left(data.info_hash, pieces)
    tracker_url = MetaInfo.announce(data.info_hash)

    params = [
      info_hash: data.info_hash,
      peer_id: data.peer_id,
      port: data.port,
      left: left,
      uploaded: data.uploaded,
      downloaded: data.downloaded
    ]

    params =
      if event do
        event = Atom.to_string(event)
        params ++ [event: event]
      else
        params
      end

    with {_, {:ok, response}} <-
           {:announce_get,
            Req.get(tracker_url,
              params: params
            )},
         {_, {:ok, decoded_announce_response, <<>>}} <-
           {:bencode_decode, Bencode.decode(response.body)},
         decoded_announce_response <-
           Map.update!(decoded_announce_response, "peers", fn peers ->
             peers
             |> parse_peers()
             |> not_me()
           end) do
      {:ok, Map.put(response, :body, decoded_announce_response)}
    end
  end

  defp parse_peers(peers) when is_binary(peers) do
    for <<a::big-integer-8, b::big-integer-8, c::big-integer-8, d::big-integer-8,
          port::big-integer-16 <- peers>> do
      %{"ip" => {a, b, c, d}, "port" => port}
    end
  end

  defp parse_peers(peers) when is_list(peers) do
    peers
    |> Enum.map(fn peer ->
      Map.update!(peer, "ip", fn ip ->
        {:ok, address} =
          ip
          |> to_charlist()
          |> :inet.parse_address()

        address
      end)
    end)
  end

  defp not_me(peers) do
    Enum.filter(peers, fn %{"ip" => ip} ->
      ip != {127, 0, 0, 1}
    end)
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
