defmodule AshEnterprise.Quality.Provenance do
  @moduledoc """
  What an `:adhoc` suite run (prompt experimentation, ADR 0058) records about the
  candidate it tried, so two candidates can be compared on more than their scores. It is
  the suite run's `summary["provenance"]`, set when it finishes:

    * `"version"`: the agent version tried (`"agent_version_id"`, `"version"`, `"status"`,
      `"content_hash"`), the key a run is compared by;
    * `"model_profile"` and `"models"`: the profile the version names, and the models
      its calls reached (`AshEnterprise.AI.ModelCall`);
    * `"configuration"`: `"limits"`, `"output_type"` and the toolset's `"targets"`;
    * `"elapsed_ms"`: the wall time from starting the suite run to scoring it, and
      `"model_ms"`, what its model calls took together;
    * `"usage"`: `"calls"`, `"input_tokens"`, `"output_tokens"` and `"unmeasured_calls"`,
      the calls that recorded no token counts;
    * `"cost"`: an amount with a label, never a bare number.

  ## Cost

  The label says how far to trust the number (`cost/2`):

    * `"estimated"`: the tokens the calls recorded priced at the rate the operator
      configured for the model (`config :ash_enterprise, #{inspect(__MODULE__)}, prices:
      %{"provider:model" => %{input_per_million: "3.00", output_per_million: "15.00",
      currency: "USD"}}`), with the amount as a decimal string;
    * `"unavailable"`: no call, a call with no token counts, or a model with no
      configured rate. There is no amount, and nothing is guessed.

  A call record carries no cost reported by the provider, so nothing here is labelled
  `"measured"` yet.
  """

  require Ash.Expr
  require Ash.Query

  alias AshEnterprise.AI.ModelCall

  @doc "The provenance of an adhoc `suite_run` that ran `version`, from its case `runs`."
  @spec build(map(), map(), [map()], DateTime.t()) :: map()
  def build(suite_run, version, runs, finished_at) do
    calls = calls(runs)
    usage = usage(calls)

    %{
      "version" => %{
        "agent_version_id" => version.id,
        "version" => version.version,
        "status" => to_string(version.status),
        "content_hash" => version.content_hash
      },
      "model_profile" => version.model_profile,
      "models" => calls |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.sort(),
      "configuration" => %{
        "limits" => stringify(version.limits),
        "output_type" => version.output_type,
        "targets" => Enum.map(version.toolset || [], &(&1["target"] || &1[:target]))
      },
      "elapsed_ms" => DateTime.diff(finished_at, suite_run.created_on, :millisecond),
      "model_ms" => calls |> Enum.map(&(&1.duration_ms || 0)) |> Enum.sum(),
      "usage" => usage,
      "cost" => cost(calls)
    }
  end

  @doc """
  The cost of `calls` (`AshEnterprise.AI.ModelCall` rows), labelled: `%{"label" =>
  "estimated", "amount" => "0.0105", "currency" => "USD"}` when every call recorded its
  tokens and its model has a configured rate, else `%{"label" => "unavailable"}`.
  """
  @spec cost([map()]) :: map()
  def cost(calls) do
    prices = Keyword.get(Application.get_env(:ash_enterprise, __MODULE__, []), :prices, %{})

    with [_ | _] <- calls,
         true <- Enum.all?(calls, &(is_integer(&1.input_tokens) and is_integer(&1.output_tokens))),
         {:ok, amounts, currency} <- price_each(calls, prices) do
      %{
        "label" => "estimated",
        "amount" =>
          amounts
          |> Enum.reduce(&Decimal.add/2)
          |> Decimal.normalize()
          |> Decimal.to_string(:normal),
        "currency" => currency
      }
    else
      _unpriced -> %{"label" => "unavailable"}
    end
  end

  defp price_each(calls, prices) do
    calls
    |> Enum.map(&price(&1, Map.get(prices, &1.model)))
    |> single_currency()
  end

  defp single_currency(priced) do
    with false <- :unpriced in priced,
         [currency] <- Enum.uniq(for {_amount, currency} <- priced, do: currency) do
      {:ok, Enum.map(priced, &elem(&1, 0)), currency}
    else
      _unpriced_or_mixed -> :unpriced
    end
  end

  defp price(call, %{input_per_million: input, output_per_million: output, currency: currency}) do
    amount =
      call.input_tokens
      |> Decimal.mult(Decimal.new(input))
      |> Decimal.add(Decimal.mult(call.output_tokens, Decimal.new(output)))
      |> Decimal.div(Decimal.new(1_000_000))

    {amount, currency}
  end

  defp price(_call, _no_rate), do: :unpriced

  defp usage(calls) do
    sum = fn field -> calls |> Enum.map(&(Map.get(&1, field) || 0)) |> Enum.sum() end

    %{
      "calls" => length(calls),
      "input_tokens" => sum.(:input_tokens),
      "output_tokens" => sum.(:output_tokens),
      "unmeasured_calls" =>
        Enum.count(calls, &(is_nil(&1.input_tokens) or is_nil(&1.output_tokens)))
    }
  end

  # The calls the runs made: a call is named `run:<run id>:<step>`.
  defp calls([]), do: []

  defp calls(runs) do
    named =
      Enum.reduce(runs, false, fn run, any ->
        prefix = "run:#{run.id}:"
        Ash.Expr.expr(^any or contains(caller, ^prefix))
      end)

    ModelCall
    |> Ash.Query.filter(^named and outcome == :ok)
    |> Ash.Query.sort(created_on: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp stringify(nil), do: %{}
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
