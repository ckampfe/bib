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

defmodule Bib.Torrent do
  @moduledoc """
  This process is the main location for a single torrent's state.
  Each torrent gets one of these processes.
  It communicates with `Peer` processes, which handle the TCP connections to remote peers.
  It deals with tracker communication.
  It's metainfo data (from the .torrent file) is stored in :persistent_term, see `name/1`
  """

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

  def get_metadata(info_hash) when is_info_hash(info_hash) do
    :gen_statem.call(name(info_hash), :get_metadata)
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

    with {:ok, response} <- announce(data, :started) do
      data = %Data{
        data
        | announce_response: response.body,
          last_announce_at: Time.utc_now()
      }

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
      {:announce_get, {:error, error}} ->
        {:stop, "error announcing `started` to tracker: #{inspect(error)}"}

      {:bencode_decode, {:error, error, position} = e} ->
        Logger.debug(
          "bencode decoding error when announcing `started`: #{error} at position #{position}"
        )

        {:stop, inspect(e)}
    end
  end

  def handle_event(:internal, :connect_to_peers, %State{}, %Data{} = data) do
    peers = Map.fetch!(data.announce_response, "peers")

    for %{"ip" => remote_peer_address, "port" => remote_peer_port, "peer id" => remote_peer_id} <-
          peers do
      Peer.connect(data.info_hash, %Peer.OutboundArgs{
        info_hash: data.info_hash,
        torrent_file: data.torrent_file,
        download_location: data.download_location,
        remote_peer_address: remote_peer_address,
        remote_peer_port: remote_peer_port,
        remote_peer_id: remote_peer_id,
        peer_id: data.peer_id,
        pieces: data.pieces,
        block_length: data.block_length
      })
    end

    {:next_state, %State{}, data, []}
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

    with {:ok, response} <- announce(data) do
      data = %Data{
        data
        | announce_response: response.body,
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
    else
      {:announce_get, {:error, error}} ->
        Logger.debug(
          "Error announcing to tracker on the regular announce interval: #{inspect(error)}"
        )

        data = %Data{
          data
          | last_announce_at: Time.utc_now()
        }

        {
          :keep_state,
          data,
          [
            {{:timeout, :announce_timer},
             :timer.seconds(Map.fetch!(data.announce_response, "interval")), :ok}
          ]
        }

      {:bencode_decode, {:error, error, position} = e} ->
        Logger.debug(
          "bencode decoding error when announcing `started`: #{error} at position #{position}"
        )

        {:stop, inspect(e)}
    end
  end

  def handle_event({:call, from}, :get_metadata, _state, %Data{} = data) do
    total_pieces = MetaInfo.number_of_pieces(data.info_hash)
    counts = Bitfield.counts(data.pieces)

    metadata = %{
      info_hash: data.info_hash,
      name: MetaInfo.name(data.info_hash),
      pieces: data.pieces,
      progress: counts.have / total_pieces * 100,
      have: counts.have,
      want: counts.want,
      seeders: 0,
      leachers: 0,
      download_speed: 0,
      upload_speed: 0
    }

    {:keep_state, data, [{:reply, from, {:ok, metadata}}]}
  end

  def handle_event({:call, from}, {:have, index}, _state, %Data{} = data) do
    data = %Data{data | pieces: Bitfield.set_bit(data.pieces, index)}
    send_to_all_peers_async(data.info_hash, {:have, index})

    %{have: have, want: want} = Bitfield.counts(data.pieces)

    if want == 0 && have == MetaInfo.number_of_pieces(data.info_hash) do
      Logger.info("Complete!")

      with {:ok, response} <- announce(data, :completed) do
        data = %Data{
          data
          | announce_response: response.body,
            last_announce_at: Time.utc_now()
        }

        {:keep_state, data, [{:reply, from, :ok}]}
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

  def handle_event({:call, from}, :get_pieces, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.pieces}}]}
  end

  def handle_event({:call, from}, :get_download_location, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.download_location}}]}
  end

  def handle_event({:call, from}, :pause, %State{} = state, %Data{} = data) do
    data =
      with {_, {:ok, response}} <- {:announce_get, announce(data, :stopped)} do
        %Data{
          data
          | announce_response: response.body,
            last_announce_at: Time.utc_now()
        }
      else
        e ->
          Logger.warning("error attempting to announce on pause: #{inspect(e)}")
          %Data{data | last_announce_at: Time.utc_now()}
      end

    # TODO
    # - [x] shutdown currently connected peers
    send_to_all_peers_async(data.info_hash, :shutdown)
    # - [_] some way to not accept new peer connections...need to set state to :paused

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

  def handle_event({:call, from}, :get_peers, %State{} = _state, %Data{} = data) do
    announce_response = Map.get(data, :announce_response, %{})
    peers = Map.get(announce_response, "peers", [])

    {:keep_state_and_data, [{:reply, from, {:ok, peers}}]}
  end

  def handle_event({:call, from}, :force_announce, %State{} = _state, %Data{} = data) do
    with {_, {:ok, response}} <- {:announce_get, announce(data)} do
      %Data{
        data
        | announce_response: response.body,
          last_announce_at: Time.utc_now()
      }

      {:keep_state, data, [{:reply, from, :ok}]}
    else
      e ->
        Logger.warning("error attempting to announce on pause: #{inspect(e)}")
        %Data{data | last_announce_at: Time.utc_now()}
        {:keep_state, data, [{:reply, from, {:error, e}}]}
    end
  end

  def name(info_hash) when is_info_hash(info_hash) do
    {:via, Registry, {Bib.Registry, {__MODULE__, info_hash}}}
  end

  # https://wiki.theory.org/BitTorrentSpecification#Tracker_Request_Parameters
  defp announce(%Data{} = data, event \\ nil)
       when event in [:started, :completed, :stopped, nil] do
    left = MetaInfo.left(data.info_hash, data.pieces)
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
