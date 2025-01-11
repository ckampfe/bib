defmodule Bib.PiecesServer do
  use GenServer
  require Bib.Macros
  import Bib.Macros
  alias Bib.Bitfield

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args.info_hash))
  end

  def insert(info_hash, pieces) when is_info_hash(info_hash) and is_bitstring(pieces) do
    GenServer.call(name(info_hash), {:insert, info_hash, pieces})
  end

  def get(info_hash) when is_info_hash(info_hash) do
    GenServer.call(name(info_hash), {:get, info_hash})
  end

  def set(info_hash, index) when is_info_hash(info_hash) and is_integer(index) do
    GenServer.call(name(info_hash), {:set, info_hash, index})
  end

  def counts(info_hash) when is_info_hash(info_hash) do
    GenServer.call(name(info_hash), {:counts, info_hash})
  end

  @impl GenServer
  def init(args) do
    Process.set_label("PiecesServer for #{Path.basename(args[:torrent_file])}")
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:insert, info_hash, pieces}, _from, state) do
    state = Map.put(state, info_hash, pieces)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:get, info_hash}, _from, state) do
    reply = Map.fetch(state, info_hash)
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call({:set, info_hash, index}, _from, state) do
    if Map.has_key?(state, info_hash) do
      state =
        Map.update!(state, info_hash, fn pieces ->
          Bitfield.set_bit(pieces, index)
        end)

      {:reply, :ok, state}
    else
      {:reply, :error, state}
    end
  end

  @impl GenServer
  def handle_call({:counts, info_hash}, _from, state) do
    with {:ok, pieces} <- Map.fetch(state, info_hash),
         counts <- Bitfield.counts(pieces) do
      {:reply, {:ok, counts}, state}
    else
      e ->
        {:reply, {:error, e}, state}
    end
  end

  defp name(info_hash) when is_info_hash(info_hash) do
    {:via, Registry, {Bib.Registry, {__MODULE__, info_hash}}}
  end
end
