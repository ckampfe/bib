defmodule Bib.ListenerServer do
  @moduledoc """
  Sets up and manages a socket that listens
  for inbound peer connections on a port.
  `AcceptorServer` processes handle the actual acceptance of those connections.
  """

  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:port]
    defstruct [:port, :listen_socket]
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def get_listen_socket do
    GenServer.call(__MODULE__, :get_listen_socket)
  end

  @impl GenServer
  def init(args) do
    {:ok, %State{port: args[:port]}, {:continue, :listen}}
  end

  @impl GenServer
  def handle_continue(:listen, %State{} = state) do
    case :gen_tcp.listen(state.port, [:binary, {:active, false}]) do
      {:ok, listen_socket} ->
        Logger.debug("peer listener started on port #{inspect(state.port)}")
        state = %State{state | listen_socket: listen_socket}
        {:noreply, state}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl GenServer
  def handle_call(:get_listen_socket, _from, %State{} = state) do
    {:reply, {:ok, state.listen_socket}, state}
  end
end
