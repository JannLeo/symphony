defmodule SymphonyElixirWeb.HermesPubSub do
  @moduledoc """
  PubSub helpers for Hermes registry dashboard updates.
  """

  @pubsub SymphonyElixir.PubSub
  @topic "hermes:registry"
  @update_message :hermes_registry_updated

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end
end
