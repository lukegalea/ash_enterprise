defmodule AshEnterprise.Test.ActionSteps do
  @moduledoc """
  What an action runs, as comparable steps, for guard tests that say "action B carries every
  step action A carries".

  AshEvents' `WrapActions` transformer wraps every action-level change in
  `AshEvents.Events.ReplayChangeWrapper` and every action-level validation in a change that
  carries `AshEvents.Events.ReplayValidationWrapper`, and adds a `Never`-gated copy of each
  `manage_relationship` for form introspection. Compared as they stand, every wrapped
  validation is the same `{ReplayValidationWrapper, nil}`, so a validation missing from one
  action is masked by any other. A step here is the thing wrapped:

      {module, key_opts}

  where `key_opts` holds the options that name what the step is about (`:attribute`,
  `:field`, `:argument`, `:relationship`) and, when the step is conditional, `where:` as the
  list of the modules its conditions are.

  `missing/2` is the comparison: the steps of the first list that the second lacks, counting
  repeats.
  """

  @key_opts [:attribute, :field, :argument, :relationship]

  @type step :: {module(), keyword()}

  @doc "The steps `action_name` of `resource` runs."
  @spec steps(Ash.Resource.t(), atom()) :: [step()]
  def steps(resource, action_name) do
    resource |> Ash.Resource.Info.action(action_name) |> action_steps()
  end

  @doc "The steps of an action struct."
  @spec action_steps(struct()) :: [step()]
  def action_steps(%{changes: changes}) do
    changes |> Enum.reject(&introspection_copy?/1) |> Enum.map(&step/1)
  end

  @doc """
  The resource-wide changes and validations that apply to `action_name`, an action of
  `action_type`, as steps. Unwraps too, so the guard holds if AshEvents wraps them.
  """
  @spec global_steps(Ash.Resource.t(), atom(), atom()) :: [step()]
  def global_steps(resource, action_type, action_name) do
    entries =
      Ash.Resource.Info.validations(resource) ++ Ash.Resource.Info.changes(resource)

    for entry <- entries,
        action_type in entry.on,
        applies_to?(entry, action_name),
        not introspection_copy?(entry),
        do: step(entry)
  end

  @doc "The steps in `expected` that `actual` lacks, counting repeats."
  @spec missing([step()], [step()]) :: [step()]
  def missing(expected, actual), do: expected -- actual

  @doc "One change or validation as a step, wrappers removed."
  @spec step(struct()) :: step()
  def step(%Ash.Resource.Validation{validation: {module, opts}} = validation),
    do: {module, key(opts, validation)}

  def step(%Ash.Resource.Change{change: {AshEvents.Events.ReplayChangeWrapper, opts}}),
    do: opts |> Keyword.fetch!(:change) |> step()

  def step(%Ash.Resource.Change{change: {AshEvents.Events.ReplayValidationWrapper, opts}}),
    do: opts |> Keyword.fetch!(:validation) |> step()

  def step(%Ash.Resource.Change{change: {module, opts}} = change),
    do: {module, key(opts, change)}

  defp key(opts, %{where: where}) do
    base = if Keyword.keyword?(opts), do: Keyword.take(opts, @key_opts), else: []

    case where do
      [_ | _] -> base ++ [where: Enum.map(where, &where_module/1)]
      _ -> base
    end
  end

  defp where_module({module, _opts}), do: module
  defp where_module(module) when is_atom(module), do: module

  defp introspection_copy?(%{where: [first | _]}),
    do: where_module(first) == AshEvents.Events.Validations.Never

  defp introspection_copy?(_entry), do: false

  # Whether a resource-wide step's `where` lets it apply to `action_name`.
  defp applies_to?(%{where: where}, action_name) do
    Enum.all?(where, fn
      {Ash.Resource.Validation.ActionIs, opts} ->
        action_name in List.wrap(opts[:action])

      {Ash.Resource.Validation.Negate, opts} ->
        case opts[:validation] do
          {Ash.Resource.Validation.ActionIs, inner} ->
            action_name not in List.wrap(inner[:action])

          _other ->
            true
        end

      _other ->
        true
    end)
  end
end
