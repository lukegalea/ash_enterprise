defmodule AshEnterprise.Planning.Fragment.Candidate do
  @moduledoc """
  The pure shape of one candidate plan a run proposed. A candidate is a proposal, never an
  operational fact: nothing reads it as one, and a person decides what becomes of it.

  Attributes, actions, validations and identities only; the host supplies tenancy,
  ownership, sealing (`assignments` is declared `sensitive?` for the host to seal),
  authority and policies. Written to move into the `ash_planning` package unchanged apart
  from its name.

  ## Axes

  | Column | Values | Written by |
  |---|---|---|
  | `check_status` | `:unchecked`, `:correct`, `:incorrect`, `:checker_failed`, `:validator_failed`, `:incomplete` | `record_check` |
  | `freshness` | `:current`, `:stale` | `mark_stale` |
  | `disposition` | `:proposed`, `:approved`, `:rejected`, `:applied`, `:superseded` | a person: `approve`, `reject`, `apply` |

  `approve` and `apply` need a `:correct` check and a `:current` candidate. `apply` here
  records the decision; the freshness recheck against the sources' `version_number`s and the
  writes to the operational resources are the host's, in one transaction around it.

  ## Obligations

  `unresolved_obligations` names what the plan could not decide, as ids and reason codes:
  `%{"id" => …, "reason" => …}` (optionally `"kind"`), strings only. It never carries a
  value.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource

  alias AshEnterprise.Planning.Fragment.Candidate.Validations

  attributes do
    uuid_primary_key :id

    attribute :run_id, :uuid do
      allow_nil? false
      public? true
      description "The run that proposed it."
    end

    attribute :index, :integer do
      allow_nil? false
      public? true
      constraints min: 0
      description "Position among the run's candidates, 0-based."
    end

    attribute :assignments, :binary do
      allow_nil? false
      public? true
      sensitive? true
      description "The typed assignments. Sealed by the host."
    end

    attribute :unresolved_obligations, {:array, :map} do
      allow_nil? false
      public? true
      default []
      description "What the plan left undecided: ids and reason codes only."
    end

    attribute :check_status, :atom do
      allow_nil? false
      public? true
      default :unchecked

      constraints one_of: [
                    :unchecked,
                    :correct,
                    :incorrect,
                    :checker_failed,
                    :validator_failed,
                    :incomplete
                  ]

      description "The MiniZinc checker and the independent validator, together."
    end

    attribute :freshness, :atom do
      allow_nil? false
      public? true
      default :current
      constraints one_of: [:current, :stale]
      description "`:stale` once a source the plan read has changed."
    end

    attribute :disposition, :atom do
      allow_nil? false
      public? true
      default :proposed
      constraints one_of: [:proposed, :approved, :rejected, :applied, :superseded]
      description "A person's decision, through an action."
    end

    attribute :applied_by_invocation_id, :uuid do
      public? true
      description "The governed invocation that applied it, when one did."
    end

    attribute :applied_by_actor_id, :uuid do
      public? true
      description "The person who applied it."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    create :propose do
      description "Record a candidate a run proposed."
      accept [:run_id, :index, :assignments, :unresolved_obligations]

      validate Validations.Obligations
    end

    update :record_check do
      description "Record the combined checker and validator outcome."
      accept [:check_status]
      require_atomic? false

      validate attribute_equals(:disposition, :proposed),
        message: "only a proposed candidate is checked"
    end

    update :mark_stale do
      description "A source the plan read has changed: the candidate can no longer be applied."
      accept []
      require_atomic? false

      validate attribute_in(:disposition, [:proposed, :approved]),
        message: "a decided candidate has nothing left to go stale"

      change set_attribute(:freshness, :stale)
    end

    update :approve do
      description "A person accepts the candidate as a plan to apply."
      accept []
      require_atomic? false

      validate attribute_equals(:disposition, :proposed),
        message: "only a proposed candidate is approved"

      validate attribute_equals(:check_status, :correct),
        message: "only a correct candidate is approved"

      validate attribute_equals(:freshness, :current),
        message: "a stale candidate is not approved"

      change set_attribute(:disposition, :approved)
    end

    update :reject do
      description "A person turns the candidate down."
      accept []
      require_atomic? false

      validate attribute_in(:disposition, [:proposed, :approved]),
        message: "only an undecided or approved candidate is rejected"

      change set_attribute(:disposition, :rejected)
    end

    update :apply do
      description "Record that a person applied an approved, current candidate."
      accept [:applied_by_invocation_id]
      require_atomic? false

      validate attribute_equals(:disposition, :approved),
        message: "only an approved candidate is applied"

      validate attribute_equals(:check_status, :correct),
        message: "only a correct candidate is applied"

      validate attribute_equals(:freshness, :current), message: "a stale candidate is not applied"

      change set_attribute(:disposition, :applied)
      change set_attribute(:applied_by_actor_id, actor(:id))
    end

    update :supersede do
      description "A newer run's candidate replaces this one."
      accept []
      require_atomic? false

      validate attribute_in(:disposition, [:proposed, :approved]),
        message: "only an undecided or approved candidate is superseded"

      change set_attribute(:disposition, :superseded)
    end
  end

  identities do
    identity :unique_run_index, [:run_id, :index]
  end
end

defmodule AshEnterprise.Planning.Fragment.Candidate.Validations.Obligations do
  @moduledoc false
  # Pure: an obligation is ids and reason codes, never a value.

  use Ash.Resource.Validation

  @allowed ~w(id kind reason)

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :unresolved_obligations) do
      obligations when is_list(obligations) ->
        if Enum.all?(obligations, &obligation?/1),
          do: :ok,
          else:
            {:error,
             field: :unresolved_obligations,
             message: "each obligation is a map of id/kind/reason strings and nothing else"}

      _other ->
        :ok
    end
  end

  defp obligation?(%{} = obligation) do
    keys = obligation |> Map.keys() |> Enum.map(&to_string/1)

    "id" in keys and "reason" in keys and Enum.all?(keys, &(&1 in @allowed)) and
      Enum.all?(obligation, fn {_key, value} -> is_binary(value) and value != "" end)
  end

  defp obligation?(_other), do: false
end
