defmodule SurrealDB.Config do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Error

  @required_fields [:endpoint, :namespace, :database]

  @spec build_client(keyword()) :: {:ok, Client.t()} | {:error, Error.t()}
  def build_client(options) when is_list(options) do
    with :ok <- validate_required_fields(options),
         {:ok, auth} <- build_auth(options) do
      {:ok,
       %Client{
         endpoint: normalize_endpoint!(Keyword.fetch!(options, :endpoint)),
         namespace: Keyword.fetch!(options, :namespace),
         database: Keyword.fetch!(options, :database),
         auth: auth,
         anonymous?: Keyword.get(options, :anonymous, false),
         request_options: Keyword.get(options, :request_options, [])
       }}
    end
  rescue
    error in ArgumentError ->
      {:error, Error.invalid_config(Exception.message(error), %{options: options})}
  end

  defp validate_required_fields(options) do
    missing =
      @required_fields
      |> Enum.filter(&blank?(Keyword.get(options, &1)))

    case missing do
      [] ->
        :ok

      _ ->
        {:error, Error.invalid_config("missing required options", %{missing: missing})}
    end
  end

  defp build_auth(options) do
    username = Keyword.get(options, :username)
    password = Keyword.get(options, :password)
    auth_token = Keyword.get(options, :auth_token)

    cond do
      present?(auth_token) and (present?(username) or present?(password)) ->
        {:error,
         Error.invalid_config(
           "auth_token cannot be combined with username/password",
           %{fields: [:auth_token, :username, :password]}
         )}

      present?(username) and present?(password) ->
        {:ok, {:basic, %{username: username, password: password}}}

      present?(username) or present?(password) ->
        {:error,
         Error.invalid_config(
           "username and password must be provided together",
           %{fields: [:username, :password]}
         )}

      present?(auth_token) ->
        {:ok, {:bearer, auth_token}}

      Keyword.get(options, :anonymous, false) == true ->
        {:ok, nil}

      true ->
        {:error,
         Error.invalid_config(
           "authentication is required unless anonymous: true is set",
           %{fields: [:username, :password, :auth_token, :anonymous]}
         )}
    end
  end

  defp normalize_endpoint!(endpoint) when is_binary(endpoint) do
    endpoint
    |> String.trim()
    |> case do
      "" -> raise ArgumentError, "endpoint must not be blank"
      value -> String.trim_trailing(value, "/")
    end
  end

  defp normalize_endpoint!(_endpoint) do
    raise ArgumentError, "endpoint must be a string"
  end

  defp blank?(value), do: not present?(value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
