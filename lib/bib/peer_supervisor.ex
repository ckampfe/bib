defmodule Bib.PeerSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg)
  end

  @impl DynamicSupervisor
  def init(init_arg) do
    Process.set_label("PeerSupervisor for #{init_arg[:torrent_file]}")

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(server, peer_args) do
    DynamicSupervisor.start_child(server, {Bib.Peer, peer_args})
  end

  def peers(server) do
    DynamicSupervisor.which_children(server)
  end
end
