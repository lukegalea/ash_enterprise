defmodule AshEnterprise.Provenance.Walk do
  @moduledoc """
  The dispatch behind `AshEnterprise.Provenance.explain/2` (ADR 0078).

  It parses and checks the address, reads the subject row as the reader, then
  asks the registry's explainers in order: the first that does not pass
  answers, and every antecedent its answer names is dispatched the same way,
  one hop deeper. It stops at `@max_depth` hops and `@max_steps` steps, and
  says so (`cut?: true` in the bounds) when a limit cut it — there is no
  silent cap.

  ## What the reader may learn

  * **An unreadable subject is not found.** A missing row, a row in another
    tenant and a row the reader may not read give the identical
    `Ash.Error.Query.NotFound`: nothing but the address was given, so nothing
    else may differ. The address checks — a known type token, a public field,
    `as_of` only on a temporal resource — run before any read, so their answer
    never depends on whether a row exists.
  * **An answer names no record the reader cannot read.** Explainers return
    labels, addresses and gaps; the walk never lets a target resource's own
    Forbidden or NotFound escape.

  An explainer whose answer holds only gaps (a failed evidence read, say) does
  not end the dispatch: the next explainer is still asked, so a `:failed` audit
  read never hides the record columns behind it. An answer with nothing in it —
  no steps, no antecedents, no gaps — is a pass the same way: the next explainer
  is asked and `answered` stays what it was, so a calculation no explainer can
  read metadata for never reads as explained.
  """

  alias AshEnterprise.Provenance.Registry
  alias AshProvenance.Address
  alias AshProvenance.Explanation, as: Answer
  alias AshProvenance.Gap

  @max_depth 4
  @max_steps 100

  @type limits :: %{required(:max_depth) => pos_integer(), required(:max_steps) => pos_integer()}

  @type state :: %{
          required(:steps) => [AshProvenance.Step.t()],
          required(:gaps) => [AshProvenance.Gap.t()],
          required(:correlation_ids) => map(),
          required(:cache) => map(),
          required(:seen) => map(),
          required(:depth) => pos_integer(),
          required(:cut?) => boolean()
        }

  @doc """
  Answers one address as the reader: `{:ok, %{explanation:, correlation_ids:}}`,
  or an `Ash.Error.Invalid` for an address that names no public value.

  `:max_depth` and `:max_steps` shrink the declared bounds, and `:registry`
  swaps the explainer registry — both for the walk's own tests; nothing may
  raise the bounds.
  """
  @spec explain(binary(), keyword()) ::
          {:ok, %{explanation: Answer.t(), correlation_ids: map()}}
          | {:error, Ash.Error.t()}
  def explain(iri, opts) do
    base = AshEnterprise.Provenance.base()

    limits = %{
      max_depth: min(Keyword.get(opts, :max_depth, @max_depth), @max_depth),
      max_steps: min(Keyword.get(opts, :max_steps, @max_steps), @max_steps)
    }

    ctx = %{
      actor: opts[:actor],
      tenant: opts[:tenant],
      base: base,
      registry: Keyword.get(opts, :registry, Registry),
      cache: %{}
    }

    with {:ok, address} <- parse(iri, base),
         {:ok, resource} <- resource(address.type, ctx),
         :ok <- check_as_of(address, resource),
         :ok <- check_field(address, resource),
         {:ok, subject} <- read_subject(address, resource, ctx) do
      walk(subject, ctx, limits)
    end
  end

  # -- The address, checked before any read -------------------------------

  defp parse(iri, base) do
    case Address.parse(iri, base: base) do
      {:ok, address} ->
        {:ok, address}

      {:error, reason} ->
        {:error, invalid_address("is not a value address of this deployment", reason)}
    end
  end

  defp resource(token, ctx) do
    case ctx.registry.resource(token) do
      {:ok, resource} -> {:ok, resource}
      :error -> {:error, invalid_address("names no known type", {:unknown_type, token})}
    end
  end

  defp check_as_of(%{as_of: nil}, _resource), do: :ok

  defp check_as_of(%{as_of: as_of}, resource) do
    if Ash.Resource.Info.temporal?(resource) do
      :ok
    else
      {:error, invalid_address("accepts as_of only on a temporal resource", as_of)}
    end
  end

  defp check_field(%{attribute: nil}, _resource), do: :ok

  defp check_field(%{attribute: attribute}, resource) do
    if public_field(resource, attribute) do
      :ok
    else
      {:error, invalid_address("names no public attribute, calculation or aggregate", attribute)}
    end
  end

  # The field is found by its declared name, never interned from the address:
  # an address may name anything, and the atom table never garbage-collects.
  defp public_field(resource, field_name) do
    Enum.any?(
      [
        Ash.Resource.Info.attributes(resource),
        Ash.Resource.Info.calculations(resource),
        Ash.Resource.Info.aggregates(resource)
      ],
      fn fields ->
        Enum.any?(fields, &(&1.public? and Atom.to_string(&1.name) == field_name))
      end
    )
  end

  defp field_atom(resource, field_name) do
    Enum.find_value(
      [
        Ash.Resource.Info.attributes(resource),
        Ash.Resource.Info.calculations(resource),
        Ash.Resource.Info.aggregates(resource)
      ],
      fn fields ->
        Enum.find_value(fields, fn field ->
          (field.public? and Atom.to_string(field.name) == field_name) && field.name
        end)
      end
    )
  end

  defp invalid_address(message, reason) do
    Ash.Error.Changes.InvalidArgument.exception(
      field: :address,
      message: message,
      value: inspect(reason)
    )
  end

  # -- The subject row, read as the reader --------------------------------

  @doc """
  The subject of `address`, read as the reader through `resource`'s own primary
  read: `{:ok, subject}`, or the one `Ash.Error.Query.NotFound` whatever the
  reason the row is not there.

  The address is not checked here; an explainer that follows an antecedent to
  another record uses this, so that a record it reads is read the way the walk
  reads the one it started from.
  """
  @spec read_subject(Address.t(), Ash.Resource.t(), map()) ::
          {:ok, AshEnterprise.Provenance.Explainer.subject()} | {:error, Ash.Error.t()}
  def read_subject(address, resource, ctx) do
    primary = Ash.Resource.Info.primary_action(resource, :read).name

    field = attribute_field(address, resource)

    query =
      resource
      |> Ash.Query.for_read(primary, %{}, actor: ctx.actor, tenant: ctx.tenant)
      |> Ash.Query.filter_input(primary_key_map(address.id, resource))
      # A calculation or an aggregate is computed here, or it would arrive as
      # `%Ash.NotLoaded{}` and read as a known empty value. Loading is the
      # reader's own read: a hidden field is `Ash.ForbiddenField`, a shredded
      # one is `Shredded`, and the answer says so.
      |> then(fn query ->
        if field && load_now?(resource, field), do: Ash.Query.load(query, [field]), else: query
      end)

    opts =
      [actor: ctx.actor, tenant: ctx.tenant] ++
        case address.as_of do
          nil -> []
          as_of -> [as_of: as_of]
        end

    case Ash.read(query, opts) do
      {:ok, [record]} -> {:ok, subject(address, resource, record)}
      {:ok, []} -> {:error, not_found(address, resource)}
      # A row the reader may not read is not found (ADR 0078, section 6);
      # whatever the target resource refused, the answer is the same as for no
      # row at all.
      {:error, _forbidden_or_other} -> {:error, not_found(address, resource)}
    end
  end

  defp subject(address, resource, record) do
    field = attribute_field(address, resource)

    %{
      address: address,
      resource: resource,
      record: record,
      field: field,
      value: field && Map.get(record, field)
    }
  end

  defp attribute_field(%{attribute: nil}, _resource), do: nil

  defp attribute_field(%{attribute: attribute}, resource) do
    field_atom(resource, attribute)
  end

  # Attributes arrive with the row; calculations and aggregates do not.
  defp load_now?(resource, field) do
    Enum.any?(
      [
        Ash.Resource.Info.calculation(resource, field),
        Ash.Resource.Info.aggregate(resource, field)
      ],
      &(&1 && &1.public?)
    )
  end

  # The pairs of a composite id are in the resource's declared primary-key
  # order (ADR 0078, section 1); a single id names its only primary-key field.
  defp primary_key_map(id, resource) when is_binary(id) do
    %{List.first(Ash.Resource.Info.primary_key(resource)) => id}
  end

  defp primary_key_map(pairs, resource) when is_list(pairs) do
    # Built from the resource's declared key names, never interned from the
    # address: a key the resource does not declare simply does not match.
    keys = Ash.Resource.Info.primary_key(resource)

    Map.new(keys, fn key ->
      name = Atom.to_string(key)
      {key, Enum.find_value(pairs, fn {k, v} -> k == name && v end)}
    end)
  end

  # One NotFound, built the same way whatever the reason the row is not there:
  # only the address was given, so every refusal must read the same.
  defp not_found(address, resource) do
    Ash.Error.Query.NotFound.exception(
      primary_key: primary_key_map(address.id, resource),
      resource: resource
    )
  end

  # -- The walk -----------------------------------------------------------

  defp walk(subject, ctx, limits) do
    state = %{
      steps: [],
      gaps: [],
      correlation_ids: %{},
      cache: ctx.cache,
      seen: %{},
      depth: 0,
      cut?: false
    }

    state = dispatch([{subject, 1}], state, ctx, limits)

    explanation =
      Answer.new!(
        subject: subject.address,
        steps: state.steps,
        gaps: state.gaps,
        bounds: %{
          max_depth: limits.max_depth,
          max_steps: limits.max_steps,
          depth: state.depth,
          step_count: length(state.steps),
          cut?: state.cut?
        }
      )

    {:ok, %{explanation: explanation, correlation_ids: state.correlation_ids}}
  end

  # Breadth-first: every antecedent an answer names is dispatched again, one
  # hop deeper, until the queue empties or a limit cuts the walk. An address
  # already explained is not explained again: two derivations sharing an input
  # give its steps once.
  defp dispatch([], state, _ctx, _limits), do: state
  defp dispatch(_queue, %{cut?: true} = state, _ctx, _limits), do: state

  defp dispatch([{subject, depth} | rest], state, ctx, limits) do
    ctx = %{ctx | cache: state.cache}
    iri = Address.to_iri(subject.address)

    cond do
      Map.has_key?(state.seen, iri) ->
        dispatch(rest, state, ctx, limits)

      depth > limits.max_depth ->
        # There was more to explain and the depth bound stopped the walk. The
        # depth reported is what was actually explained, never the hop that
        # was refused.
        dispatch(rest, %{state | cut?: true}, ctx, limits)

      true ->
        case prepare(subject, ctx) do
          {:ok, subject, cache} ->
            state = %{
              state
              | seen: Map.put(state.seen, iri, true),
                depth: max(state.depth, depth),
                cache: cache,
                gaps: state.gaps ++ erased_gaps(subject, ctx)
            }

            {state, next} = ask(subject, depth, state, ctx, limits)
            dispatch(next ++ rest, state, ctx, limits)

          {:error, gap} ->
            # Loading the antecedent's calculation as the reader failed: a
            # failed gap in its place, and the walk moves on.
            dispatch(
              rest,
              %{state | gaps: state.gaps ++ [gap], seen: Map.put(state.seen, iri, true)},
              ctx,
              limits
            )
        end
    end
  end

  # A shredded value reads as `%AshEnterprise.Erasure.Shredded{}` (ADR 0024):
  # the answer says so with a `:erased` gap, and the dispatch continues as
  # usual — the write history is not erased, so the audit explainer still
  # answers. No step carries the shredded value: `render_value/3` shows
  # nothing for it.
  defp erased_gaps(
         %{value: %AshEnterprise.Erasure.Shredded{} = value, address: address},
         ctx
       ) do
    [Gap.new!(kind: :erased, of: address, receipt: receipt(value.erasure_scope_id, ctx))]
  end

  # A person erasure also *blanks* the plaintext `sensitive?` attributes it does
  # not shred (a person's name, their blind index, the pre-seal column), so they
  # read as plain nil. Only a person erasure blanks them, so a nil on a row that
  # still carries its erasure scope reads as erased — and its receipt is named
  # as for a shredded value, only to a reader who may read one; a reader who may
  # not is told nothing about an erase. The dispatch continues either way: the
  # write history is not erased, so the audit explainer still answers. Nothing
  # else is read.
  defp erased_gaps(
         %{value: nil, address: address, resource: resource, record: record, field: field},
         ctx
       ) do
    with %Ash.Resource.Attribute{sensitive?: true} <- Ash.Resource.Info.attribute(resource, field),
         %Ash.Resource.Attribute{} <-
           Ash.Resource.Info.attribute(resource, :erasure_scope_id),
         scope_id when not is_nil(scope_id) <- record.erasure_scope_id,
         found when not is_nil(found) <- receipt(scope_id, ctx) do
      [Gap.new!(kind: :erased, of: address, receipt: found)]
    else
      _not_a_blanked_field_or_no_receipt -> []
    end
  end

  defp erased_gaps(_subject, _ctx), do: []

  # The shred's receipt is named only to a reader who may read one (ADR 0078,
  # section 3): a Forbidden read, or no receipt for the scope, leaves the gap
  # with nothing that says an erase happened.
  defp receipt(scope_id, ctx) do
    case AshEnterprise.Erasure.person_erasure_by_shredded_scope(scope_id,
           actor: ctx.actor,
           tenant: ctx.tenant
         ) do
      {:ok, %{id: id}} when not is_nil(id) ->
        "person_erasure:" <> to_string(id)

      {:ok, nil} ->
        nil

      {:error, _forbidden_or_other} ->
        nil
    end
  end

  # An antecedent that is a calculation arrives as `%Ash.NotLoaded{}` — the
  # subject row was loaded before the walk knew this field mattered. Load it
  # on the record as the reader, or answer with a failed gap.
  defp prepare(%{resource: resource, record: record, field: field} = subject, ctx) do
    cond do
      is_nil(field) or not calculation?(resource, field) or
          not match?(%Ash.NotLoaded{}, Map.get(record, field)) ->
        {:ok, subject, ctx.cache}

      is_nil(ctx.tenant) ->
        # Loading needs the reader's tenancy, which a walk of a resource that
        # carries none does not have; the value stays what it is.
        {:ok, subject, ctx.cache}

      true ->
        case Ash.load(record, [field], actor: ctx.actor, tenant: ctx.tenant) do
          {:ok, record} ->
            {:ok, %{subject | record: record, value: Map.get(record, field)}, ctx.cache}

          {:error, _forbidden_or_other} ->
            {:error, Gap.new!(kind: :failed, of: subject.address)}
        end
    end
  end

  defp calculation?(resource, field) do
    case Ash.Resource.Info.calculation(resource, field) do
      nil -> false
      calculation -> calculation.public?
    end
  end

  # The first explainer that answers gives its steps; an answer that holds only
  # gaps does not end the dispatch — the next explainer is still asked.
  @spec ask(AshEnterprise.Provenance.Explainer.subject(), pos_integer(), state(), map(), limits()) ::
          {state(), [{AshEnterprise.Provenance.Explainer.subject(), pos_integer()}]}
  defp ask(subject, depth, state, ctx, limits) do
    subject.resource
    |> ctx.registry.explainers_for(subject.field)
    |> Enum.reduce_while({state, false, []}, &ask_one(&1, &2, subject, depth, ctx, limits))
    |> then(fn {state, answered, next} ->
      {if(answered, do: state, else: add_not_recorded(state, subject)), next}
    end)
  end

  defp ask_one(explainer, {state, answered, next}, subject, depth, ctx, limits) do
    case explainer.explain(subject, ctx) do
      :pass ->
        {:cont, {state, answered, next}}

      {:ok, answer} ->
        state =
          state
          |> take_steps(answer, limits)
          |> take_gaps(answer)
          |> take_correlations(answer)
          |> take_cache(answer)

        conclude(answer, state, answered, next, depth)
    end
  end

  # The step bound cut the answer; the walk stops here.
  defp conclude(_answer, %{cut?: true} = state, _answered, _next, _depth) do
    {:halt, {state, true, []}}
  end

  # Nothing in the answer: a pass, not an answered question. The next
  # explainer is asked, and `answered` stays what it was — its cache and
  # correlation ids are merged already, and merging them is harmless.
  defp conclude(%{steps: [], antecedents: []} = answer, state, answered, next, _depth)
       when answer.gaps in [nil, []] do
    {:cont, {state, answered, next}}
  end

  # A gap-only answer: the next explainer may still add steps.
  defp conclude(%{steps: [], antecedents: []}, state, _answered, _next, _depth) do
    {:cont, {state, true, []}}
  end

  defp conclude(answer, state, _answered, _next, depth) do
    {:halt, {state, true, Enum.map(answer.antecedents, &{&1, depth + 1})}}
  end

  defp take_steps(state, answer, limits) do
    {taken, rest} = Enum.split(answer.steps, limits.max_steps - length(state.steps))

    if rest == [] do
      %{state | steps: state.steps ++ taken}
    else
      # The step bound cut the answer: what would not fit is dropped, and the
      # bounds say so.
      %{state | steps: state.steps ++ taken, cut?: true}
    end
  end

  defp take_gaps(state, answer), do: %{state | gaps: state.gaps ++ List.wrap(answer.gaps)}

  defp take_correlations(state, answer) do
    correlations = Map.get(answer, :correlation_ids, %{})
    %{state | correlation_ids: Map.merge(state.correlation_ids, correlations)}
  end

  defp take_cache(state, answer) do
    %{state | cache: Map.merge(state.cache, Map.get(answer, :cache, %{}))}
  end

  defp add_not_recorded(state, subject) do
    gap = Gap.new!(kind: :not_recorded, of: subject.address)
    %{state | gaps: state.gaps ++ [gap]}
  end
end
