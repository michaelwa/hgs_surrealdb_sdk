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

  @spec validation(String.t(), map()) :: t()
  def validation(message, details \\ %{}) do
    %__MODULE__{type: :validation, message: message, details: details}
  end

  @spec request(Exception.t() | term()) :: t()
  def request(%{message: message} = error) when is_binary(message) do
    %__MODULE__{
      type: :request,
      message: message,
      details: %{exception: error.__struct__},
      raw: error
    }
  end

  def request(error) do
    %__MODULE__{
      type: :request,
      message: "request failed",
      raw: error
    }
  end

  @spec http_failure(integer(), term()) :: t()
  def http_failure(status, body) do
    %__MODULE__{
      type: :http,
      status: status,
      message: "HTTP request failed with status #{status}",
      details: extract_error_details(body),
      raw: body
    }
  end

  @spec decode_failure(binary(), term()) :: t()
  def decode_failure(body, reason) do
    %__MODULE__{
      type: :decode,
      message: "failed to decode SurrealDB response",
      details: %{body: body, reason: inspect(reason)},
      raw: reason
    }
  end

  @spec surreal_failure(map()) :: t()
  def surreal_failure(statement) do
    %__MODULE__{
      type: :surreal,
      code: statement["code"],
      message: statement["detail"] || statement["result"] || "SurrealDB query failed",
      details: Map.take(statement, ["detail", "status", "time"]),
      raw: statement
    }
  end

  defp extract_error_details(%{"error" => error}) when is_binary(error), do: %{error: error}
  defp extract_error_details(%{"detail" => detail}) when is_binary(detail), do: %{detail: detail}
  defp extract_error_details(_body), do: %{}
end
