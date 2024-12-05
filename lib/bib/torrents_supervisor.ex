defmodule Bib.TorrentsSupervisor do
  @moduledoc """
  Supervises all torrent trees
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one, extra_arguments: [init_arg])
  end

  def start_child(torrent_args) do
    DynamicSupervisor.start_child(__MODULE__, {Bib.TorrentSupervisor, torrent_args})
  end

  def stop_child(info_hash) do
    [{pid, _}] = Registry.lookup(Bib.Registry, {Bib.TorrentSupervisor, info_hash})
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
