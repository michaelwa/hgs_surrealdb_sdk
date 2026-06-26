defmodule Mix.Tasks.Surreal.CreateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Surreal.Create

  setup do
    Mix.Task.reenable("app.start")
    Mix.Task.reenable("surreal.create")

    :ok
  end

  test "creates the database and installs schema_migrations in the target scope" do
    previous = Application.get_env(:req, :default_options)

    calls =
      scripted_calls([
        fn request ->
          assert Req.Request.get_header(request, "ns") == ["app4"]
          assert Req.Request.get_header(request, "db") == ["app4"]
          assert request.body =~ "DEFINE NAMESPACE IF NOT EXISTS app4"
          assert request.body =~ "DEFINE DATABASE IF NOT EXISTS app4"
          ok_response(request, [])
        end,
        fn request ->
          assert Req.Request.get_header(request, "ns") == ["app4"]
          assert Req.Request.get_header(request, "db") == ["app4"]
          assert request.body =~ "DEFINE TABLE IF NOT EXISTS schema_migrations SCHEMAFULL"
          ok_response(request, [])
        end
      ])

    Application.put_env(:req, :default_options, adapter: scripted(calls))

    on_exit(fn ->
      if previous do
        Application.put_env(:req, :default_options, previous)
      else
        Application.delete_env(:req, :default_options)
      end
    end)

    output =
      capture_io(fn ->
        Create.run_create(["--namespace", "app4", "--database", "app4"])
      end)

    assert output =~ "Created SurrealDB namespace/database app4/app4."
    assert output =~ "Installed SurrealDB migration registry in app4/app4."
    assert_no_remaining_calls(calls)
  end

  defp scripted_calls(funs) do
    {:ok, agent} = Agent.start_link(fn -> funs end)
    agent
  end

  defp scripted(agent) do
    fn request ->
      fun =
        Agent.get_and_update(agent, fn
          [fun | rest] -> {fun, rest}
          [] -> {nil, []}
        end)

      if is_function(fun, 1) do
        fun.(request)
      else
        flunk("unexpected request: #{request.body}")
      end
    end
  end

  defp assert_no_remaining_calls(agent) do
    assert Agent.get(agent, & &1) == []
  end

  defp ok_response(request, result) do
    {request, Req.Response.new(status: 200, body: [%{"status" => "OK", "result" => result}])}
  end
end
