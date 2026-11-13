defmodule AshEnterprise.A2uiMessage do
  @moduledoc """
  The A2UI 1.0 renderer-to-agent messages this application builds or reads.

  A renderer drives a surface through one message: a `callAgentFunction` calling the
  ash_a2ui catalog's `ashAction` (`AshA2ui.ActionHandler` refuses a plain `action` event).
  The browser's renderer builds it from the control it was drawn for; the server builds the
  same message where there is no browser, such as a report the page runs for the person
  (`AshEnterpriseWeb.DailyLive`) and the tests.
  """

  @doc """
  The `callAgentFunction` message for the `ashAction` named `name` on a surface, with
  `context` as the action's context. The surface is its id, or the UI module that declares
  it.
  """
  @spec ash_action(String.t() | module(), String.t(), map(), keyword()) :: map()
  def ash_action(surface, name, context \\ %{}, opts \\ [])

  def ash_action(ui, name, context, opts) when is_atom(ui),
    do: ash_action(AshA2ui.ResolvedView.resolve(ui, []).surface_id, name, context, opts)

  def ash_action(surface_id, name, context, opts) do
    %{
      "version" => "1.0",
      "callAgentFunction" => %{
        "surfaceId" => surface_id,
        "functionCallId" => Keyword.get_lazy(opts, :call_id, &call_id/0),
        "callFunction" => %{
          "@call" => "ashAction",
          "catalogId" => AshA2ui.Encoder.ash_catalog_id(),
          "args" => %{
            "name" => name,
            "sourceComponentId" => Keyword.get(opts, :source, name),
            "context" => context
          }
        }
      }
    }
  end

  @doc """
  The action name and context a `callAgentFunction` message calls `ashAction` with, or
  `:error` for anything else (a plain `action` event, another function, a malformed
  message).
  """
  @spec parse(term()) :: {:ok, String.t(), map()} | :error
  def parse(%{
        "callAgentFunction" => %{
          "callFunction" => %{"@call" => "ashAction", "args" => %{"name" => name} = args}
        }
      })
      when is_binary(name),
      do: {:ok, name, context(args)}

  def parse(_message), do: :error

  @doc "The surface id a renderer message names, or nil."
  @spec surface_id(term()) :: String.t() | nil
  def surface_id(%{"callAgentFunction" => %{"surfaceId" => id}}) when is_binary(id), do: id
  def surface_id(%{"action" => %{"surfaceId" => id}}) when is_binary(id), do: id
  def surface_id(%{"error" => %{"surfaceId" => id}}) when is_binary(id), do: id
  def surface_id(_message), do: nil

  defp context(%{"context" => %{} = context}), do: context
  defp context(_args), do: %{}

  defp call_id, do: "fc_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
