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
  alias SurrealDB.Identifier

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

  @spec select(Client.t(), String.t()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def select(%Client{} = client, thing) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "SELECT * FROM #{identifier}")
    end
  end

  @spec create(Client.t(), String.t(), map()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def create(%Client{} = client, thing, data) when is_map(data) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "CREATE #{identifier} CONTENT $data", %{data: data})
    end
  end

  @spec update(Client.t(), String.t(), map()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def update(%Client{} = client, thing, data) when is_map(data) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "UPDATE #{identifier} CONTENT $data", %{data: data})
    end
  end

  @spec merge(Client.t(), String.t(), map()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def merge(%Client{} = client, thing, data) when is_map(data) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "UPDATE #{identifier} MERGE $data", %{data: data})
    end
  end

  @spec patch(Client.t(), String.t(), list()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def patch(%Client{} = client, thing, operations) when is_list(operations) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "UPDATE #{identifier} PATCH $patch", %{patch: operations})
    end
  end

  @spec delete(Client.t(), String.t()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def delete(%Client{} = client, thing) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "DELETE #{identifier}")
    end
  end
end
