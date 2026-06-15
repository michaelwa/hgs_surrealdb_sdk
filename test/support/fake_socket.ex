defmodule SurrealDB.WebSocketTest.FakeSocket do
  @moduledoc false

  def start_link(owner, url, headers, options) do
    test_pid = Keyword.fetch!(options, :test_pid)
    auto_setup = Keyword.get(options, :auto_setup, false)

    pid =
      spawn_link(fn ->
        send(test_pid, {:fake_socket_started, owner, url, headers, self()})
        send(owner, {:websocket_connected, self()})
        loop(owner, test_pid, auto_setup)
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

  defp loop(owner, test_pid, auto_setup) do
    receive do
      {:send_text, payload} ->
        send(test_pid, {:socket_sent, owner, payload})

        if auto_setup do
          decoded = Jason.decode!(payload)

          if decoded["method"] in ["signin", "authenticate", "use"] do
            send(
              owner,
              {:websocket_frame, Jason.encode!(%{id: decoded["id"], result: %{"ok" => true}})}
            )
          end
        end

        loop(owner, test_pid, auto_setup)

      :close ->
        send(owner, {:websocket_closed, :normal})
        :ok

      other ->
        send(test_pid, {:fake_socket_unexpected, other})
        loop(owner, test_pid, auto_setup)
    end
  end
end
