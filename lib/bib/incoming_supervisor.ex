defmodule Bib.IncomingSupervisor do
  @moduledoc """
  Supervises the `Listener` and `Acceptor` processes
  for a given torrent.
  """

  use Supervisor
  alias Bib.{AcceptorServer, ListenerServer}

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(args) do
    children = [
      {ListenerServer, args}
    ]

    acceptors =
      Enum.map(1..args[:acceptors], fn i ->
        Supervisor.child_spec({AcceptorServer, %{i: i}},
          id: {AcceptorServer, i}
        )
      end)

    children = children ++ acceptors

    Supervisor.init(children, strategy: :one_for_one)
  end
end
