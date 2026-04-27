defmodule SurrealDB.Error do
  @moduledoc false

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          status: integer() | nil,
          code: String.t() | nil,
          details: map(),
          raw: term()
        }

  defexception [:type, :message, :status, :code, details: %{}, raw: nil]

  @spec invalid_config(String.t(), map()) :: t()
  def invalid_config(message, details \\ %{}) do
    %__MODULE__{type: :invalid_config, message: message, details: details}
  end

  @spec http_error(Exception.t() | integer() | term(), map() | term()) :: t()
  def http_error(%{message: message} = error, details)
      when is_binary(message) and is_map(details) do
    %__MODULE__{
      type: :http_error,
      message: message,
      details: Map.merge(%{exception: error.__struct__}, details),
      raw: error
    }
  end

  def http_error(status, body) when is_integer(status) do
    %__MODULE__{
      type: :http_error,
      status: status,
      message: "HTTP request failed with status #{status}",
      details: extract_error_details(body),
      raw: body
    }
  end

  def http_error(error, details) when is_map(details) do
    %__MODULE__{
      type: :http_error,
      message: "request failed",
      details: details,
      raw: error
    }
  end

  @spec decode_error(binary(), term()) :: t()
  def decode_error(body, reason) do
    %__MODULE__{
      type: :decode_error,
      message: "failed to decode SurrealDB response",
      details: %{body: body, reason: inspect(reason)},
      raw: reason
    }
  end

  @spec surreal_error(map()) :: t()
  def surreal_error(statement) do
    %__MODULE__{
      type: :surreal_error,
      code: statement["code"],
      message: statement["detail"] || statement["result"] || "SurrealDB query failed",
      details: Map.take(statement, ["detail", "status", "time"]),
      raw: statement
    }
  end

  @spec unexpected_response(term()) :: t()
  def unexpected_response(body) do
    %__MODULE__{
      type: :unexpected_response,
      message: "unexpected response shape",
      details: %{body: inspect(body)},
      raw: body
    }
  end

  defp extract_error_details(%{"error" => error}) when is_binary(error), do: %{error: error}
  defp extract_error_details(%{"detail" => detail}) when is_binary(detail), do: %{detail: detail}
  defp extract_error_details(body), do: %{body: body}
end
