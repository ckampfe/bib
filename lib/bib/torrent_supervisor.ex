defmodule Bib.TorrentSupervisor do
  use Supervisor
  require Logger
  import Bib.Macros

  def start_link(extra_args, args) do
    args = Map.merge(extra_args, args)
    Supervisor.start_link(__MODULE__, args, name: name(args.info_hash))
  end

  @impl Supervisor
  def init(args) do
    Process.set_label("TorrentSupervisor for #{Path.basename(args[:torrent_file])}")

    children = [
      {Bib.PeerSupervisor, args},
      {Bib.Torrent, args}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def name(info_hash) when is_info_hash(info_hash) do
    {:via, Registry, {Bib.Registry, {__MODULE__, info_hash}}}
  end
end
