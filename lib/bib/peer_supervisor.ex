defmodule Bib.PeerSupervisor do
  @moduledoc """
  This process starts and supervises `Peer` processes.
  Every torrent gets one.
  It is supervised by a `TorrentSupervisor` process.
  """

  use DynamicSupervisor
  require Logger
  import Bib.Macros

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: name(args.info_hash))
  end

  @impl DynamicSupervisor
  def init(args) do
    Process.set_label("PeerSupervisor for #{Path.basename(args[:torrent_file])}")

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(info_hash, peer_args) do
    server = name(info_hash)
    DynamicSupervisor.start_child(server, {Bib.PeerServer, peer_args})
  end

  def peers(info_hash) when is_info_hash(info_hash) do
    server = name(info_hash)

    server
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {:undefined, pid, :worker, [Bib.PeerServer]} -> pid end)
  end

  def name(info_hash) when is_info_hash(info_hash) do
    {:via, Registry, {Bib.Registry, {__MODULE__, info_hash}}}
  end
end
