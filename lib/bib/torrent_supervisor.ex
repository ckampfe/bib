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
      {Bib.TorrentState, init_arg}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def torrent_state_worker(torrent_file) do
    {_, pid, _, _} =
      torrent_file
      |> name()
      |> Supervisor.which_children()
      |> Enum.find(fn {module, _pid, _kind, _} -> module == Bib.TorrentState end)

    pid
  end

  def peer_supervisor(torrent_file) do
    {_, pid, _, _} =
      torrent_file
      |> name()
      |> Supervisor.which_children()
      |> Enum.find(fn {module, _pid, _kind, _} -> module == Bib.PeerSupervisor end)

    pid
  end

  def name(torrent_file) do
    {:via, Registry, {Bib.Registry, torrent_file}}
  end
end
