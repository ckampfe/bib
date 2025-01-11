defmodule Bib.AcceptorServer do
  @moduledoc """
  This process attempts to accept TCP connections from remote bittorrent peers.

  If a remote peer successfully connects to us via this process, the connection is
  handed off to a new `Peer` process for the respective torrent,
  and this process goes back to accepting more TCP connections.

  It does this in a loop.
  """

  use GenServer

  alias Bib.{PeerServer, TorrentServer, ListenerServer}

  require Logger

  defmodule State do
    defstruct [:listen_socket]
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args) do
    Process.set_label("Elixir.Bib.AcceptorServer ##{args[:i]}")
    {:ok, %State{}, {:continue, :get_listen_socket}}
  end

  @impl GenServer
  def handle_continue(:get_listen_socket, %State{} = state) do
    {:ok, listen_socket} = ListenerServer.get_listen_socket()
    state = %State{state | listen_socket: listen_socket}
    Process.send(self(), :accept, [])
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:accept, %State{} = state) do
    with {_, {:ok, socket}} <-
           {:accept, :gen_tcp.accept(state.listen_socket, :timer.seconds(5))},
         {_, :ok} <-
           {:handshake_setopts,
            :inet.setopts(
              socket,
              [
                :binary,
                {:packet, 0},
                {:active, false},
                {:send_timeout, :timer.seconds(5)},
                {:send_timeout_close, true}
              ]
            )},
         {_, {:ok, {remote_peer_address, remote_peer_port}}} <-
           {:peername, :inet.peername(socket)},
         _ = Logger.debug("accepted connection from #{inspect(remote_peer_address)}"),
         {_, {:ok, %{challenge_info_hash: challenge_info_hash, remote_peer_id: remote_peer_id}}} <-
           {:receive_handshake, PeerServer.receive_handshake(socket)},
         {_, true} <-
           {:torrent_accepting_connections?,
            TorrentServer.accepting_connections?(challenge_info_hash)},
         {_, {:ok, peer_id}} <- {:get_peer_id, TorrentServer.get_peer_id(challenge_info_hash)},
         {_, {:ok, download_location}} <-
           {:get_download_location, TorrentServer.get_download_location(challenge_info_hash)},
         {_, {:ok, peer_pid}} <-
           {:peer_accept,
            PeerServer.accept_remote_peer_connection(challenge_info_hash, %PeerServer.InboundArgs{
              info_hash: challenge_info_hash,
              socket: socket,
              peer_id: peer_id,
              download_location: download_location,
              remote_peer_id: remote_peer_id,
              remote_peer_address: remote_peer_address,
              remote_peer_port: remote_peer_port
            })},
         {_, :ok} <- {:controlling_process, :gen_tcp.controlling_process(socket, peer_pid)},
         {_, :ok} <- {:send_handshake, PeerServer.handshake_peer(peer_pid)} do
      Logger.debug(
        "Received handshake from peer id #{Base.encode64(remote_peer_id)}, with challenge info hash #{Base.encode64(challenge_info_hash)}"
      )

      Logger.debug(
        "we have a valid Torrent for #{Base.encode64(challenge_info_hash)}, it is with peer id#{inspect(peer_id)}"
      )

      Logger.debug("started peer #{inspect(peer_pid)} to handle #{inspect(remote_peer_address)}")

      Process.send(self(), :accept, [])

      {:noreply, state}
    else
      # the timeout is intentionally set,
      # we don't need to be crashing/flapping if a receive times out,
      # just try to receive again
      {:accept, {:error, :timeout}} ->
        Process.send(self(), :accept, [])
        {:noreply, state}

      {:torrent_accepting_connections?, _} ->
        Logger.debug("torrent is not accepting connections")
        Process.send(self(), :accept, [])
        {:noreply, state}

      {:accept, {:error, :closed}} ->
        Logger.debug("listen socket closed (in acceptor)")
        {:stop, :normal}

      {:accept, {:error, :system_limit}} ->
        {:stop, "reached system limit trying to accept a new socket", state}

      {:accept, {:error, posix}} ->
        {:stop, "posix error when accepting connection: #{inspect(posix)}", state}

      {:handshake_setopts, {:error, error}} ->
        {:stop, "error in handshake setopts: #{inspect(error)}", state}

      {:receive_handshake, {:error, error}} ->
        {:stop, "error receiving handshake #{inspect(error)}", state}

      {:peername, {:error, error}} ->
        {:stop, "error in getting peername: #{inspect(error)}", state}

      {:get_peer_id, error} ->
        {:stop, "error getting peer_id from Torrent process #{inspect(error)}", state}

      {:peer_accept, {:error, error}} ->
        {:stop, "error starting peer process for connection #{inspect(error)}", state}

      {:controlling_process, {:error, error}} ->
        {:stop, "error setting controlling process: #{inspect(error)}", state}

      unknown_error ->
        {:stop,
         "unknown error occurred when accepting connection from new peer: #{inspect(unknown_error)}",
         state}
    end
  end
end
