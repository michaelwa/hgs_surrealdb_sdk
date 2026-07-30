defmodule SurrealDB.WebSocketTest.FakeSocket do
  @moduledoc false

  def start_link(owner, url, headers, options) do
    test_pid = Keyword.fetch!(options, :test_pid)
    auto_setup = Keyword.get(options, :auto_setup, false)
    setup_responses = Keyword.get(options, :setup_responses, %{})
    setup_delays = Keyword.get(options, :setup_delays, %{})

    pid =
      spawn_link(fn ->
        send(test_pid, {:fake_socket_started, owner, url, headers, self()})
        send(owner, {:websocket_connected, self()})
        loop(owner, test_pid, auto_setup, setup_responses, setup_delays)
      end)

    {:ok, pid}
  end

  def send_text(pid, payload) do
    send(pid, {:send_text, payload})
    :ok
  end

  def close(pid) do
    send(pid, :close)
    :ok
  end

  defp loop(owner, test_pid, auto_setup, setup_responses, setup_delays) do
    receive do
      {:send_text, payload} ->
        send(test_pid, {:socket_sent, owner, payload})

        if auto_setup do
          decoded = Jason.decode!(payload)

          if decoded["method"] in ["signin", "authenticate", "use"] do
            response =
              case Map.get(setup_responses, decoded["method"], {:ok, %{"ok" => true}}) do
                {:ok, result} -> %{id: decoded["id"], result: result}
                {:error, error} -> %{id: decoded["id"], error: error}
              end

            case Map.get(setup_delays, decoded["method"], 0) do
              0 -> send(owner, {:websocket_frame, Jason.encode!(response)})
              delay -> Process.send_after(self(), {:deliver_setup, owner, response}, delay)
            end
          end
        end

        loop(owner, test_pid, auto_setup, setup_responses, setup_delays)

      {:deliver_setup, owner, response} ->
        send(owner, {:websocket_frame, Jason.encode!(response)})
        loop(owner, test_pid, auto_setup, setup_responses, setup_delays)

      :close ->
        send(owner, {:websocket_closed, :normal})
        :ok

      other ->
        send(test_pid, {:fake_socket_unexpected, other})
        loop(owner, test_pid, auto_setup, setup_responses, setup_delays)
    end
  end
end
