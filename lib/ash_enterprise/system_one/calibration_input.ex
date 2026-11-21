defmodule AshEnterprise.SystemOne.CalibrationInput do
  @moduledoc """
  The host's `:calibration_input` seam for `mix ash_judgments.calibrate`:
  a family's labelled pairs, read from an exported eval-set file.

      config :ash_judgments, :calibration_input, {#{inspect(__MODULE__)}, :load, []}

  The package never sees a model or an eval store, so the pairs come from
  the host. This host keeps them as a file per family,
  `<eval_set_dir>/<family>.eval-set.json`, written once from the judgment
  ledger by the family's exporter (for `third_party_licence`,
  `AshEnterprise.Licences.EvalSet`). Reading a file rather than the ledger
  keeps the seam free of a database (the task boots no repo), makes the
  eval set a reviewable artifact, and gives `eval_set_hash` a plain meaning:
  the sha256 of the file's bytes.

  `eval_set_dir` comes from `config :ash_enterprise, #{inspect(__MODULE__)}`
  (`S1_EVAL_SET_DIR` in `config/runtime.exs`). With no directory, or no file
  for the family, the seam refuses rather than inventing pairs. Only the
  `eval_set` source exists here; `shadow_ledger` is refused.

  Only the questions the family declares now calibrate it. A file saved
  before a question moved to another family still names that question, in
  its `question_hashes` and its pairs' `question_hash` and `question`; it
  is refused (`{:questions_outside_family, names}`), and so is a hash no
  declared question has. Rebuild the file from the ledger instead.

  ## The file

      {
        "family": "...", "answer_kind": "noul",
        "question_hashes": ["sha256:..."],
        "model_version": "...", "model_digest": "sha256:...",
        "runtime_version": "...", "region": "...", "tenant": "...",
        "created_by": "...", "observations_digest": "sha256:...",
        "pairs": [{"p": 0.97, "gold": true, ...}]
      }

  For a noul family, each pair is the model's probability of `true` and the
  gold answer; the conformal pairs score that same probability against
  `gold == true`.
  """

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc "The seam: `load(family, source) :: {:ok, input} | {:error, reason}`."
  @spec load(String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def load(family, :eval_set) do
    with {:ok, dir} <- eval_set_dir(),
         path = Path.join(dir, "#{family}.eval-set.json"),
         {:ok, bytes} <- read(path),
         {:ok, doc} <- Jason.decode(bytes),
         :ok <- same_family(doc, family),
         :ok <- own_questions(doc) do
      {:ok, input(doc, bytes)}
    end
  end

  def load(_family, source), do: {:error, {:unsupported_source, source}}

  @doc """
  The seam input for a decoded eval-set document and its bytes. Raises when
  the document holds a question its family does not declare.
  """
  @spec input(map(), binary()) :: map()
  def input(doc, bytes) do
    case own_questions(doc) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end

    kind = answer_kind(doc["answer_kind"])
    pairs = Enum.map(doc["pairs"], &pair(kind, &1))

    %{
      answer_kind: kind,
      pairs: pairs,
      scored: Enum.map(pairs, &{&1.p, &1.gold == true}),
      question_hashes: doc["question_hashes"],
      model_version: doc["model_version"],
      model_digest: doc["model_digest"],
      runtime_version: doc["runtime_version"],
      eval_set_hash: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      region: doc["region"],
      tenant: doc["tenant"],
      created_by: doc["created_by"],
      observations_digest: doc["observations_digest"],
      n_per_class: n_per_class(pairs)
    }
  end

  @doc """
  The §8.1 run inputs for `AshEnterprise.SystemOne.Calibration.record_run/2`,
  assembled from a seam input by the package's own modules, exactly as
  `mix ash_judgments.calibrate` assembles them: `Calibration.Metrics` for
  the metrics, and `Calibration.conformal_thresholds/2` for the thresholds
  earned at the family's α (the upper one, and the lower one when earned)
  with the coverage of the table they render.

  The task's own recording path cannot be used on this host: its create
  carries no actor and no tenant, and `CalibrationRun` is tenanted and
  written by system actors only. `record_run/2` is the host's recording
  path, and runs the same proposal trigger before the create.
  """
  @spec run_attrs(String.t(), map(), keyword()) :: map()
  def run_attrs(family, %{answer_kind: :noul} = input, opts \\ []) do
    metrics = AshJudgments.Calibration.Metrics.noul_metrics(input.pairs)

    %{
      family: family,
      question_hashes: input.question_hashes,
      model_version: input.model_version,
      model_digest: input.model_digest,
      runtime_version: input.runtime_version,
      eval_set_hash: input.eval_set_hash,
      region: input.region,
      n: length(input.pairs),
      n_per_class: input.n_per_class,
      metrics: metrics,
      ece: metrics["ece"],
      brier: metrics["brier"],
      conformal_thresholds: AshJudgments.Calibration.conformal_thresholds(family, input.scored),
      source: Keyword.get(opts, :source, :eval_set),
      created_by: input.created_by,
      observations_digest: input.observations_digest,
      tenant: input.tenant,
      pass_bar: %{},
      finished_at: DateTime.utc_now()
    }
  end

  @doc "The questions this application declares in `family`."
  @spec family_questions(String.t()) :: [AshJudgments.Registry.Question.t()]
  def family_questions(family) do
    Enum.filter(declared_questions(), &(Atom.to_string(&1.family) == family))
  end

  defp declared_questions do
    for module <- Application.spec(:ash_enterprise, :modules) || [],
        question <- AshJudgments.Registry.Info.questions(module),
        do: question
  end

  defp own_questions(%{"family" => family} = doc) do
    own = family_questions(family)
    names = Map.new(declared_questions(), &{&1.question_hash, Atom.to_string(&1.name)})
    own_hashes = MapSet.new(own, & &1.question_hash)
    own_names = MapSet.new(own, &Atom.to_string(&1.name))
    pairs = doc["pairs"] || []

    hashes =
      (doc["question_hashes"] || [])
      |> Enum.concat(Enum.map(pairs, & &1["question_hash"]))
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(own_hashes, &1)))
      |> Enum.map(&Map.get(names, &1, &1))

    named =
      pairs
      |> Enum.map(& &1["question"])
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(own_names, &1)))

    case (hashes ++ named) |> Enum.uniq() |> Enum.sort() do
      [] -> :ok
      outside -> {:error, {:questions_outside_family, outside}}
    end
  end

  defp pair(:noul, %{"p" => p, "gold" => gold}) when is_boolean(gold), do: %{p: p / 1, gold: gold}

  defp answer_kind("noul"), do: :noul
  defp answer_kind(other), do: raise(ArgumentError, "unsupported answer kind #{inspect(other)}")

  defp n_per_class(pairs) do
    pairs
    |> Enum.frequencies_by(&to_string(&1.gold))
  end

  defp eval_set_dir do
    case Application.get_env(:ash_enterprise, __MODULE__, [])[:eval_set_dir] do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _unset -> {:error, :eval_set_dir_not_configured}
    end
  end

  # The directory is host configuration (`S1_EVAL_SET_DIR`), and the family is
  # the calibrate task's argument, run by an operator; never request input.
  @sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:no_eval_set, path, reason}}
    end
  end

  defp same_family(%{"family" => family}, family), do: :ok
  defp same_family(%{"family" => other}, family), do: {:error, {:family_mismatch, other, family}}
end
