defmodule AshEnterprise.Quality.Interchange.EvalLog do
  @moduledoc """
  Inspect EvalLog v2 for suite runs (ADR 0058): `build/1` writes a suite run and its case
  results as the JSON `inspect log convert --to json` produces, `parse/1` reads one back
  into case results.

  The format is Inspect's (https://inspect.aisi.org.uk/eval-logs.html.md), which makes
  no compatibility promise. So:

    * the log is checked against the vendored schema (`schema_path/0`, `validate/1`),
      the `components.schemas.EvalLog` of `inspect log schema`, pinned in
      `docs/BLEEDING-EDGE.md`;
    * `decode/1` tolerates the `NaN` and `Infinity` Python writes, reading them as null;
    * a binary `.eval` log is never parsed: convert it to JSON with Inspect first.

  ## Mapping

  A suite is the task and its case ids the dataset's sample ids. A case result is a
  sample: the case's `input` and `target`, and one Inspect `Score` per assertion result,
  named `type` (or `type:target`), valued `"C"` (passed), `"I"` (failed) or `"N"`
  (unmeasured). A judged score is named `judged:<scorer>`. What Inspect has no field for
  rides in the score's `metadata` (`"assertion"` or `"judged"`, the whole entry) and the
  sample's, so a log this module wrote parses back to the same case ids and scores. A
  score from another tool has no such metadata: its value is read, and its name is the
  assertion type.

  The answer is not logged: the sample's output completion is empty.
  """

  alias AshEnterprise.Quality.Assertions

  @version 2
  @doc "The EvalLog version this module writes and reads."
  @spec version() :: 2
  def version, do: @version

  @schema_path Path.expand("../../../../priv/quality/inspect/inspect-log-schema.json", __DIR__)

  # Law 16: the schema is read at compile time, so editing it recompiles this module.
  @external_resource @schema_path

  @root @schema_path
        |> File.read!()
        |> Jason.decode!()
        |> Map.take(["components"])
        |> Map.put("$ref", "#/components/schemas/EvalLog")
        |> JSV.build!()

  @doc "The path of the vendored `inspect log schema` output."
  @spec schema_path() :: Path.t()
  def schema_path, do: @schema_path

  @doc """
  The EvalLog for a suite run: `%{suite:, suite_run:, results:}`, where `results` are
  case results (`AshEnterprise.Quality.CaseResult` structs or maps with the same keys)
  and `suite_run.summary["judged"]` is carried in the log's metadata.
  """
  @spec build(%{suite: map(), suite_run: map(), results: [map()]}) :: map()
  def build(%{suite: suite, suite_run: run, results: results}) do
    cases = Map.new(suite.cases, &{&1[:id], &1})
    ids = Enum.map(suite.cases, & &1[:id])
    order = ids |> Enum.with_index() |> Map.new()

    samples =
      results
      |> Enum.sort_by(&{order[&1.case_id], &1.epoch})
      |> Enum.map(&sample(&1, cases[&1.case_id]))

    created = iso(Map.get(run, :finished_at) || DateTime.utc_now())

    %{
      "version" => @version,
      "status" => "success",
      "eval" => %{
        "eval_id" => run.id,
        "run_id" => run.id,
        "created" => created,
        "task" => suite.key,
        "task_id" => "#{suite.key}@#{suite.version}",
        "task_version" => suite.version,
        "task_attribs" => %{},
        "task_args" => %{},
        "task_args_passed" => %{},
        "dataset" => %{"name" => suite.key, "samples" => length(ids), "sample_ids" => ids},
        "model" => "agent/#{run.agent_key}",
        "model_generate_config" => %{},
        "model_args" => %{},
        "config" => %{},
        "packages" => %{},
        "metadata" =>
          drop_nil(%{
            "suite_content_hash" => run.suite_content_hash,
            "candidate_digest" => run.candidate_digest,
            "mode" => to_string(run.mode)
          })
      },
      "plan" => %{"name" => "plan", "steps" => [], "config" => %{}},
      "results" => %{
        "total_samples" => length(samples),
        "completed_samples" => Enum.count(samples, &(&1["metadata"]["status"] != "errored")),
        "scores" => result_scores(samples)
      },
      "stats" => %{
        "started_at" => "",
        "completed_at" => created,
        "model_usage" => %{},
        "role_usage" => %{},
        "connection_limit_history" => []
      },
      "invalidated" => false,
      "tags" => [],
      "metadata" => drop_nil(%{"judged" => (run.summary || %{})["judged"]}),
      "samples" => samples
    }
  end

  @doc """
  The case results in an EvalLog, as the attributes `CaseResult`'s `record` takes
  (without the suite run): `{:ok, %{results: [...], judged: map | nil}}`, or
  `{:error, message}` for a log that is not version 2 or has no samples.
  """
  @spec parse(map()) :: {:ok, %{results: [map()], judged: map() | nil}} | {:error, String.t()}
  def parse(%{"version" => @version, "samples" => samples} = log) when is_list(samples) do
    {:ok,
     %{
       results: Enum.map(samples, &result/1),
       judged: get_in(log, ["metadata", "judged"])
     }}
  end

  def parse(%{"version" => version}) when version != @version,
    do: {:error, "an EvalLog of version #{inspect(version)} is not read; version 2 is"}

  def parse(_log), do: {:error, "not an EvalLog with samples"}

  @doc """
  Decodes EvalLog JSON, reading `NaN`, `Infinity` and `-Infinity` (which Python writes
  and JSON does not have) as null.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, Exception.t()}
  def decode(json) when is_binary(json) do
    ~r/"(?:[^"\\]|\\.)*"|-?Infinity|NaN/
    |> Regex.replace(json, &blank/1)
    |> Jason.decode()
  end

  defp blank(<<?", _::binary>> = string), do: string
  defp blank(_non_finite), do: "null"

  @doc "The log as JSON."
  @spec encode(map()) :: binary()
  def encode(log), do: Jason.encode!(log, pretty: true)

  @doc """
  Checks `log` against the vendored schema: `:ok`, or `{:error, message}` naming what
  the schema refuses.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(log) do
    case JSV.validate(log, @root) do
      {:ok, _cast} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  ## Writing

  defp sample(result, kase) do
    kase = kase || %{}
    scores = scores(result)

    %{
      "id" => result.case_id,
      "epoch" => result.epoch,
      "input" => kase[:input] || "",
      "target" => kase[:target] || "",
      "messages" => [],
      "output" => %{"model" => "agent", "choices" => [], "completion" => ""},
      "scores" => Map.new(scores),
      "metadata" =>
        drop_nil(%{
          "status" => to_string(result.status),
          "prohibited_effect_hit" => result.prohibited_effect_hit,
          "run_id" => result.run_id,
          "tags" => kase[:tags],
          "split" => kase[:split] && to_string(kase[:split])
        }),
      "store" => %{},
      "events" => [],
      "model_usage" => %{},
      "role_usage" => %{},
      "attachments" => %{}
    }
    |> put_error(result)
  end

  defp put_error(sample, %{status: :errored}),
    do:
      Map.put(sample, "error", %{
        "message" => "the case's run did not complete",
        "traceback" => "",
        "traceback_ansi" => ""
      })

  defp put_error(sample, _result), do: sample

  # [{score name, Score}] in order: assertions, then judged scores. Each score's metadata
  # keeps its place, so a read gives the results back in the order they were written.
  defp scores(result) do
    assertions = Enum.map(result.assertion_results, &{assertion_name(&1), assertion_score(&1)})
    judged = Enum.map(result.scores, &{"judged:" <> &1["scorer"], judged_score(&1)})

    (assertions ++ judged)
    |> unique()
    |> Enum.with_index()
    |> Enum.map(fn {{name, score}, index} ->
      {name, put_in(score, ["metadata", "index"], index)}
    end)
  end

  defp assertion_name(%{"type" => type, "target" => target}) when target not in [nil, ""],
    do: type <> ":" <> target

  defp assertion_name(%{"type" => type}), do: type

  defp assertion_score(result) do
    %{
      "value" => value(result["status"]),
      "explanation" => result["detail"],
      "history" => [],
      "metadata" => %{"assertion" => result}
    }
  end

  defp judged_score(entry) do
    %{
      "value" => value(judged_status(entry["status"])),
      "history" => [],
      "metadata" => %{"judged" => entry}
    }
  end

  defp judged_status("compliant"), do: "passed"
  defp judged_status("violating"), do: "failed"
  defp judged_status(_unknown), do: "unmeasured"

  defp value("passed"), do: "C"
  defp value("failed"), do: "I"
  defp value(_unmeasured), do: "N"

  defp unique(named) do
    {named, _seen} =
      Enum.map_reduce(named, %{}, fn {name, score}, seen ->
        n = Map.get(seen, name, 0) + 1
        {{if(n == 1, do: name, else: "#{name}##{n}"), score}, Map.put(seen, name, n)}
      end)

    named
  end

  # One EvalScore per scorer: the share of its measured samples that passed.
  defp result_scores(samples) do
    samples
    |> Enum.flat_map(fn sample ->
      Enum.map(sample["scores"], fn {name, score} -> {scorer(name), score["value"]} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(fn {scorer, values} ->
      passed = Enum.count(values, &(&1 == "C"))
      scored = Enum.count(values, &(&1 in ["C", "I"]))

      %{
        "name" => scorer,
        "scorer" => scorer,
        "params" => %{},
        "metrics" =>
          if(scored == 0,
            do: %{},
            else: %{
              "accuracy" => %{"name" => "accuracy", "value" => passed / scored, "params" => %{}}
            }
          ),
        "scored_samples" => scored,
        "unscored_samples" => length(values) - scored
      }
    end)
  end

  defp scorer(name),
    do: name |> String.replace(~r/#\d+$/, "") |> String.split(":") |> scorer_head()

  defp scorer_head(["judged", scorer | _]), do: "judged:" <> scorer
  defp scorer_head([type | _]), do: type

  ## Reading

  defp result(sample) do
    metadata = sample["metadata"] || %{}
    scores = sample["scores"] || %{}

    # In the order they were written (`scores/1`); a score from another tool has no place
    # and comes last, by name.
    ordered =
      Enum.sort_by(scores, fn {name, score} ->
        {get_in(score, ["metadata", "index"]) || :infinity, name}
      end)

    assertion_results =
      for {name, score} <- ordered, not judged?(score), do: assertion_result(name, score)

    judged = for {_name, score} <- ordered, judged?(score), do: judged_entry(score)

    %{
      case_id: to_string(sample["id"]),
      epoch: sample["epoch"] || 1,
      status: status(metadata, assertion_results, sample),
      assertion_results: assertion_results,
      scores: judged,
      prohibited_effect_hit: metadata["prohibited_effect_hit"] == true,
      run_id: uuid(metadata["run_id"])
    }
  end

  defp judged?(score), do: is_map(get_in(score, ["metadata", "judged"]))

  defp judged_entry(score), do: score["metadata"]["judged"]

  defp assertion_result(name, %{"metadata" => %{"assertion" => %{} = result}})
       when is_binary(name),
       do: result

  defp assertion_result(name, score) do
    %{
      "type" => scorer(name),
      "target" => nil,
      "hard" => false,
      "status" => read_value(score["value"]),
      "detail" => score["explanation"] || ""
    }
  end

  defp read_value(value) when value in ["C", "CORRECT", 1, 1.0, true], do: "passed"
  defp read_value(value) when value in ["I", "INCORRECT", 0, 0.0, false], do: "failed"
  defp read_value(_other), do: "unmeasured"

  defp status(%{"status" => status}, _results, _sample)
       when status in ~w(passed failed errored skipped unmeasured),
       do: String.to_existing_atom(status)

  defp status(_metadata, results, sample),
    do: Assertions.case_status(results, is_nil(sample["error"]))

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_other), do: nil

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp drop_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
