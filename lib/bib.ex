defmodule Bib do
  import Bib.Macros
  alias Bib.Torrent

  # big stuff to do:
  # - [ ] seeding
  # - [ ] actual peer choke/unchoke/upload algorithm
  # - [ ] tracking of upload/download stats per peer
  # - [ ] configurability (connection limits, etc.)
  # - [ ] mutliple files in a single torrent
  # - [x] force update tracker
  # - [x] verify local data
  # - [x] remove torrent
  # - [x] pause torrent
  # - [x] resume torrent
  # - [ ] ability to change listen port
  # - [x] get peers api
  # - [x] force announce api

  alias Bib.{Bencode, MetaInfo}

  @moduledoc """
  Documentation for `Bib`.
  """

  def all_info_hashes do
    Registry.select(Bib.Registry, [
      {{{Bib.Torrent, :"$1"}, :"$2", :_}, [], [:"$1"]}
    ])
  end

  def torrent_metadata(info_hash) when is_info_hash(info_hash) do
    Torrent.get_metadata(info_hash)
  end

  def add_torrent(torrent_file, download_location) do
    # TODO probably move most of this into the Torrent process
    with {:ok, metainfo_binary} <- File.read(torrent_file),
         {:ok, decoded, <<>>} <- Bencode.decode(metainfo_binary),
         info_hash = MetaInfo.new(decoded),
         {:ok, _pid} <-
           Bib.TorrentsSupervisor.start_child(%{
             info_hash: info_hash,
             torrent_file: torrent_file,
             download_location: download_location
           }) do
      {:ok, info_hash}
    end
  end

  def pause_torrent(info_hash) when is_info_hash(info_hash) do
    Torrent.pause(info_hash)
  end

  def resume_torrent(info_hash) when is_info_hash(info_hash) do
    Torrent.resume(info_hash)
  end

  def remove_torrent(info_hash) when is_info_hash(info_hash) do
    Bib.TorrentsSupervisor.stop_child(info_hash)
    :persistent_term.erase(Bib.MetaInfo.key(info_hash))
    :ok
  end

  def get_peers(info_hash) when is_info_hash(info_hash) do
    Torrent.get_peers(info_hash)
  end

  def force_announce(info_hash) when is_info_hash(info_hash) do
    Torrent.force_announce(info_hash)
  end

  def verify_local_data(info_hash) when is_info_hash(info_hash) do
    Torrent.verify_local_data(info_hash)
  end

  def s() do
    add_torrent("/Users/clark/code/bib/a8dmfmt66t211.png.torrent", "/Users/clark/code/bib")
  end

  def a() do
    add_torrent(
      "/Users/clark/code/bib/fanimatrix_local.avi.torrent",
      "/Users/clark/code/bib"
    )
  end

  def aa() do
    add_torrent(
      "/Users/clark/code/bib/The-Fanimatrix-(DivX-5.1-HQ).avi.torrent",
      "/Users/clark/code/bib"
    )
  end

  def ubuntu() do
    add_torrent(
      "/Users/clark/Downloads/ubuntu-24.04.1-desktop-amd64.iso.torrent",
      "/Users/clark/code/bib"
    )
  end
end
