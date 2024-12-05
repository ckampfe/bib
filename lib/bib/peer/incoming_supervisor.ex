defmodule Bib.Peer.IncomingSupervisor do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(args) do
    children = [
      {Bib.Peer.Listener, args}
    ]

    acceptors =
      Enum.map(1..args[:acceptors], fn i ->
        Supervisor.child_spec({Bib.Peer.Acceptor, %{i: i}},
          id: {Bib.Peer.Acceptor, i}
        )
      end)

    children = children ++ acceptors

    Supervisor.init(children, strategy: :one_for_one)
  end
end
