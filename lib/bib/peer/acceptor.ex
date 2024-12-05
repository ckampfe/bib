defmodule Bib.Peer.Acceptor do
  use GenServer

  alias Bib.Torrent
  alias Bib.Peer

  require Logger

  defmodule State do
    defstruct [:listen_socket]
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args) do
    Process.set_label("Elixir.Bib.Peer.Acceptor ##{args[:i]}")
    {:ok, %State{}, {:continue, :get_listen_socket}}
  end

  @impl GenServer
  def handle_continue(:get_listen_socket, %State{} = state) do
    {:ok, listen_socket} = Bib.Peer.Listener.get_listen_socket()
    state = %State{state | listen_socket: listen_socket}
    Process.send(self(), :accept, [])
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:accept, %State{} = state) do
    with {_, {:ok, socket}} <-
           {:accept, :gen_tcp.accept(state.listen_socket, :timer.seconds(5))},
         _ = Logger.debug("accepted!"),
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
         {_, {:ok, remote_peer_address}} <- {:peername, :inet.peername(socket)},
         {_, {:ok, %{challenge_info_hash: challenge_info_hash, remote_peer_id: remote_peer_id}}} <-
           {:receive_handshake, Peer.receive_handshake(socket)},
         {_, {:ok, peer_id}} <- {:get_peer_id, Torrent.get_peer_id(challenge_info_hash)},
         {_, {:ok, download_location}} <-
           {:get_download_location, Torrent.get_download_location(challenge_info_hash)},
         {_, {:ok, peer_pid}} <-
           {:peer_accept,
            Peer.accept_remote_peer_connection(challenge_info_hash, %Peer.AcceptArgs{
              info_hash: challenge_info_hash,
              socket: socket,
              peer_id: peer_id,
              download_location: download_location,
              remote_peer_id: remote_peer_id,
              remote_peer_address: remote_peer_address
            })},
         {_, :ok} <- {:controlling_process, :gen_tcp.controlling_process(socket, peer_pid)},
         {_, :ok} <- {:send_handshake, Peer.handshake_peer(peer_pid)} do
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
      {:accept, {:error, :closed}} ->
        Logger.debug("listen socket closed (in acceptor)")
        {:stop, :normal}

      {:accept, {:error, :timeout}} ->
        Process.send(self(), :accept, [])
        {:noreply, state}

      {:accept, {:error, :system_limit}} ->
        raise "reached system limit trying to accept a new socket"

      {:handshake_setopts, {:error, error}} ->
        raise "error in handshake setopts: #{inspect(error)}"

      {:receive_handshake, {:error, error}} ->
        raise "error receiving handshake #{inspect(error)}"

      {:peername, {:error, error}} ->
        raise "error in getting peername: #{inspect(error)}"

      {:get_peer_id, error} ->
        raise "error getting peer_id from Torrent process #{inspect(error)}"

      {:peer_accept, {:error, error}} ->
        raise "error starting peer process for connection #{inspect(error)}"

      {:controlling_process, {:error, error}} ->
        raise "error setting controlling process: #{inspect(error)}"

      unknown_error ->
        raise "unknown error occurred when accepting connection from new peer: #{inspect(unknown_error)}"
    end
  end
end
