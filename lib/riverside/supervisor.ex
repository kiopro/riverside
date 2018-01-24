defmodule Riverside.Supervisor do

  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init([handler, opts]) do
    children(handler, opts)
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp children(handler, opts) do
    [
      Riverside.Stats,
      {Riverside.EndpointSupervisor, [handler, opts]},
      {TheEnd.AcceptanceStopper, [
        timeout:  0,
        endpoint: Riverside.Supervisor,
        gatherer: TheEnd.ListenerGatherer.Plug
      ]}
    ]
  end

end
