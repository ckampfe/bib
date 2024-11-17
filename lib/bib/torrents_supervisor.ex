defmodule Bib.TorrentsSupervisor do
  @moduledoc """
  Supervises all torrent trees
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(torrent_args) do
    DynamicSupervisor.start_child(__MODULE__, {Bib.TorrentSupervisor, torrent_args})
  end
end
