defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  @session_options [
    store: :cookie,
    key: "_symphony_elixir_key",
    signing_salt: "symphony-session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  @parser_options Plug.Parsers.init(
                    parsers: [:urlencoded, :multipart, :json],
                    pass: ["*/*"],
                    json_decoder: Jason
                  )

  plug(:parse_body)

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SymphonyElixirWeb.Router)

  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, @parser_options)
  rescue
    Plug.Parsers.ParseError ->
      body = Jason.encode!(%{error: %{code: "invalid_json", message: "Request body must be valid JSON"}})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, body)
      |> Plug.Conn.halt()
  end
end
