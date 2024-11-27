defmodule Bib.PeerSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: name(args.info_hash))
  end

  @impl DynamicSupervisor
  def init(args) do
    Process.set_label("PeerSupervisor for #{Path.basename(args[:torrent_file])}")

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(info_hash, peer_args) do
    DynamicSupervisor.start_child(name(info_hash), {Bib.Peer, peer_args})
  end

  def peers(info_hash) do
    info_hash
    |> name()
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {:undefined, pid, :worker, [Bib.Peer]} -> pid end)
  end

  def name(info_hash) do
    {:via, Registry, {Bib.Registry, {__MODULE__, info_hash}}}
  end
end
