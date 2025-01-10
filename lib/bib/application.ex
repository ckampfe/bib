defmodule Bib.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # port = 6881 + :rand.uniform(2 ** 15 - 6881)
    port = 6881

    children =
      case Application.get_env(:bib, :env) do
        # do not start the tree in test,
        # we will start it manually if we want it
        :test ->
          []

        _ ->
          [
            {
              Registry,
              keys: :unique, name: Bib.Registry, partitions: System.schedulers_online()
            },
            {Task.Supervisor, name: Bib.TaskSupervisor},
            {
              PartitionSupervisor,
              child_spec: Bib.PiecesServer.child_spec(%{}),
              name: Bib.PiecesPartitionSupervisor,
              partitions: System.schedulers_online()
            },
            {Bib.Peer.IncomingSupervisor, acceptors: System.schedulers_online(), port: port},
            {Bib.TorrentsSupervisor, %{port: port}}
          ]
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bib.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
