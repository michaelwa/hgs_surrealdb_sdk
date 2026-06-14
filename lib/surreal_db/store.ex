defmodule SurrealDB.Store do
  @moduledoc """
  Defines a supervised, config-driven SurrealDB connection (Ecto.Repo-style).

      defmodule MyApp.SurrealStore do
        use SurrealDB.Store, otp_app: :my_app
      end

      # config/runtime.exs
      config :my_app, MyApp.SurrealStore,
        endpoint: "http://localhost:8000",
        namespace: "app",
        database: "app",
        username: "root",
        password: "root",
        transport: :http

  Add the module to your supervision tree (`children = [MyApp.SurrealStore]`),
  then call the connection-bound API without an explicit client:

      MyApp.SurrealStore.query("SELECT * FROM person")
      MyApp.SurrealStore.get(MyApp.User, "user:abc")
      MyApp.SurrealStore.create(MyApp.User, %{name: "Jane"})
  """

  alias SurrealDB.Client
  alias SurrealDB.Error

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @otp_app Keyword.fetch!(opts, :otp_app)

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(opts \\ []) do
        SurrealDB.Store.Supervisor.start_link(__MODULE__, @otp_app, opts)
      end

      def config, do: SurrealDB.Store.config(@otp_app, __MODULE__)
      def client, do: SurrealDB.Store.fetch_client(__MODULE__)

      # Raw API (delegates to SurrealDB.*)
      def query(surql, vars \\ %{}) do
        with {:ok, c} <- client(), do: SurrealDB.query(c, surql, vars)
      end

      def rpc(method, params) do
        with {:ok, c} <- client(), do: SurrealDB.rpc(c, method, params)
      end

      def live(query, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.live(c, query, opts)
      end

      def kill(subscription) do
        with {:ok, c} <- client(), do: SurrealDB.kill(c, subscription)
      end

      # Schema-CRUD (delegates to SurrealDB.Repo.*)
      def get(schema, id, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.get(c, schema, id, opts)
      end

      def all(schema, filters \\ %{}, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.all(c, schema, filters, opts)
      end

      def find(schema, filters, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.find(c, schema, filters, opts)
      end

      def create(schema, attrs, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.create(c, schema, attrs, opts)
      end

      def update(schema, id, attrs, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.update(c, schema, id, attrs, opts)
      end

      def delete(schema, id, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.delete(c, schema, id, opts)
      end

      # Schema query (arity 3/4 only — avoids collision with raw query/1,2)
      def query(schema, surql, vars, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.query(c, schema, surql, vars, opts)
      end
    end
  end

  @doc false
  @spec config(atom(), module()) :: keyword()
  def config(otp_app, store) do
    Application.get_env(otp_app, store, [])
  end

  @doc false
  @spec fetch_client(module()) :: {:ok, Client.t()} | {:error, Error.t()}
  def fetch_client(store) do
    case :persistent_term.get({__MODULE__, store}, :not_started) do
      :not_started -> {:error, Error.not_started(store)}
      %Client{} = client -> resolve_transport(store, client)
    end
  end

  defp resolve_transport(_store, %Client{transport: :http} = client), do: {:ok, client}

  defp resolve_transport(store, %Client{transport: :websocket} = client) do
    case Registry.lookup(SurrealDB.Store.Registry, store) do
      [{pid, _value}] -> {:ok, %Client{client | connection: pid}}
      [] -> {:error, Error.not_connected(store)}
    end
  end

  defp resolve_transport(store, %Client{}), do: {:error, Error.not_connected(store)}
end
