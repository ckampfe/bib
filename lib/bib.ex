defmodule Bib do
  @moduledoc """
  Documentation for `Bib`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Bib.hello()
      :world

  """
  def hello do
    :world
  end

  def start_torrent(torrent_file, download_location) do
    Bib.TorrentsSupervisor.start_child(%{
      torrent_file: torrent_file,
      download_location: download_location
    })
  end

  def s() do
    start_torrent("/Users/clark/code/bib/a8dmfmt66t211.png.torrent", "/Users/clark/code/bib")
  end
end
