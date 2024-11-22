defmodule Bib.TorrentSupervisor do
  use Supervisor
  require Logger

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: name(init_arg[:torrent_file]))
  end

  @impl Supervisor
  def init(init_arg) do
    Process.set_label("TorrentSupervisor for #{init_arg[:torrent_file]}")

    children = [
      {Bib.PeerSupervisor, init_arg},
      {Bib.Torrent, init_arg}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def name(torrent_file) do
    {:via, Registry, {Bib.Registry, {__MODULE__, torrent_file}}}
  end
end
