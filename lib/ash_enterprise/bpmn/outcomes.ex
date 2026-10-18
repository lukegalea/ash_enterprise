defmodule AshEnterprise.Bpmn.Outcomes do
  @moduledoc """
  The outcomes a person may complete a human task with, and how the task
  acts report a refusal.

  A user task declares its outcomes in its BPMN (`<ash:outcomes>`), and the
  diagram routes on them: an outcome the step does not declare reaches a
  gateway that has no flow for it and takes its default, so a typo in a free
  text box used to decide the task as whatever the default branch means. The
  board's Complete prompt therefore offers a picker, and every completion path
  here refuses an outcome the step does not declare, whatever the client sent.

  The declared list is `HumanTask.declared_outcomes`, read from the definition
  the task's instance pinned (a platform baseline's too, which the engine's
  own `:outcomes` misses). A task whose step declares none — a
  standalone approval — accepts any non-empty outcome, as before. A task
  whose definition cannot be read accepts none: "could not tell" is not
  "declares none", and the engine routes on whatever outcome it is given.

  ## The picker

  The board's prompt is an `ash_a2ui` ChoicePicker over the Complete action's
  enumerated `outcome` argument, whose values are fixed when the resource
  compiles: every outcome a checked-in baseline (`priv/bpmn/*.bpmn`) declares
  (`offered/0`). A prompt's options cannot vary per card (the protocol's
  ChoicePicker takes literal options), so the picker on one card can show an
  outcome another step declares; the action refuses it with the outcomes this
  step does declare, and the task's detail lists them. Per-card options need
  per-record prompt options in `ash_a2ui`.
  """

  # Compile-time constants from the checked-in baselines, so the atoms below
  # come from our own files, never from input (iron law #10's documented
  # exception). Adding or removing a baseline recompiles this module.
  @baselines Path.wildcard(Path.expand("../../../priv/bpmn/*.bpmn", __DIR__))
  for baseline <- @baselines, do: @external_resource(baseline)

  @offered @baselines
           |> Enum.flat_map(fn path ->
             Regex.scan(~r/<ash:outcome\s+name="([^"]+)"/, File.read!(path),
               capture: :all_but_first
             )
           end)
           |> List.flatten()
           |> Enum.uniq()

  @doc false
  def __mix_recompile__?,
    do: Path.wildcard(Path.expand("../../../priv/bpmn/*.bpmn", __DIR__)) != @baselines

  @doc "Every outcome a checked-in baseline declares, in first-seen order: the picker's choices."
  @spec offered() :: [String.t()]
  def offered, do: @offered

  # The atoms are minted once, here, while the module compiles, from the
  # outcome names scanned out of the checked-in baselines above. Nothing at
  # runtime converts a string to an atom, so the atom set is closed over our
  # own files (iron law #10).
  @offered_atoms Enum.map(@offered, &String.to_atom/1)

  @doc "`offered/0` as atoms, for the Complete action's `one_of` constraint."
  @spec offered_atoms() :: [atom()]
  def offered_atoms, do: @offered_atoms

  @doc """
  The outcomes `task`'s step declares: `{:ok, outcomes}`, `{:ok, nil}` when
  it declares none (or is a standalone approval), `{:error, :unresolved}`
  when its definition could not be read. The definition is read with the
  engine's authority (`AshEnterprise.Bpmn.Calculations.DeclaredOutcomes`).
  """
  @spec declared(struct()) :: {:ok, [String.t()] | nil} | {:error, :unresolved}
  def declared(task) do
    [declared] = AshEnterprise.Bpmn.Calculations.DeclaredOutcomes.resolve([task])
    declared
  end

  @doc """
  `:ok` when `outcome` is one `task`'s step declares (or it declares none);
  an error when it is not, or when the step's outcomes could not be read.
  """
  @spec check(struct(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def check(task, outcome, _opts) do
    case declared(task) do
      {:ok, nil} ->
        :ok

      {:ok, outcomes} ->
        if outcome in outcomes,
          do: :ok,
          else: {:error, "this step's outcomes are #{sentence(outcomes)}"}

      {:error, :unresolved} ->
        {:error, "this step's outcomes could not be read, so it cannot be completed now"}
    end
  end

  @doc """
  A task act's refusal as the error the surface shows: the engine's candidacy
  refusals (`ArgumentError`: not a candidate, not the holder, excluded) as
  `Forbidden`; a sentence about the person's input as an invalid argument on
  `field`; any Ash error as it is.
  """
  @spec refusal(term(), atom()) :: Exception.t()
  def refusal(%ArgumentError{}, _field), do: Ash.Error.Forbidden.exception([])
  def refusal(%{__exception__: true} = error, _field), do: error

  def refusal(reason, field),
    do: Ash.Error.Changes.InvalidArgument.exception(field: field, message: to_string(reason))

  defp sentence([one]), do: one

  defp sentence(outcomes),
    do: Enum.join(Enum.drop(outcomes, -1), ", ") <> " or " <> List.last(outcomes)
end
