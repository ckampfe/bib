defmodule Bib.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # port = 6881 + :rand.uniform(2 ** 15 - 6881)
    port = 6881

    children = [
      {
        Registry,
        keys: :unique, name: Bib.Registry, partitions: System.schedulers_online()
      },
      {Bib.Peer.IncomingSupervisor, acceptors: System.schedulers_online(), port: port},
      {Bib.TorrentsSupervisor, %{port: port}}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bib.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
