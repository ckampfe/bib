defmodule Bib.PeerSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: name(init_arg[:torrent_file]))
  end

  @impl DynamicSupervisor
  def init(init_arg) do
    Process.set_label("PeerSupervisor for #{init_arg[:torrent_file]}")

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(torrent_file, peer_args) do
    DynamicSupervisor.start_child(name(torrent_file), {Bib.Peer, peer_args})
  end

  def peers(torrent_file) do
    DynamicSupervisor.which_children(name(torrent_file))
  end

  def name(torrent_file) do
    {:via, Registry, {Bib.Registry, {__MODULE__, torrent_file}}}
  end
end
