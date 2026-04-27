defmodule SurrealDB do
  @moduledoc """
  Public API for the minimal HTTP-based SurrealDB client.

  ## Example

      {:ok, client} =
        SurrealDB.connect(
          endpoint: "http://localhost:8000",
          namespace: "test",
          database: "test",
          username: "root",
          password: "root"
        )

      SurrealDB.query(client, "SELECT * FROM person")
  """

  alias SurrealDB.Client
  alias SurrealDB.Config
  alias SurrealDB.HTTP

  @spec connect(keyword()) :: {:ok, Client.t()} | {:error, SurrealDB.Error.t()}
  def connect(options) when is_list(options) do
    Config.build_client(options)
  end

  @spec query(Client.t(), iodata()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def query(%Client{} = client, query) when is_binary(query) or is_list(query) do
    HTTP.query(client, IO.iodata_to_binary(query))
  end

  @spec query(Client.t(), iodata(), map()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def query(%Client{} = client, query, variables)
      when (is_binary(query) or is_list(query)) and is_map(variables) do
    HTTP.query(client, IO.iodata_to_binary(query), variables)
  end
end
