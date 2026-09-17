defmodule AshEnterprise.Compliance.Kyc do
  @moduledoc """
  The KYC review flow: how a compliance fact payload becomes compliance
  events, and how the projector turns those into findings.

  Two entry points:

    * `record_from_projection/2` — called by the strangler ingester after it
      projects a legacy user. Derives what the legacy row can say (lifecycle
      state, e-mail domain) and records the review with everything else
      absent, so the finding honestly reads "unknown" until a human completes
      the review.
    * `record_review/3` — the compliance officer's review: supplies the
      screening and identity outcomes the legacy estate cannot.

  Both append to `AshEnterprise.Compliance.EventLog`; the projector does the
  rest. Nothing here evaluates rules or writes findings — that duplication
  would be a second engine with half the rules.

  ## One event per control

  The finding grain is `[organization_id, control_id, subject_type,
  subject_id]`, and the projector's translation combines only the rules
  filed under the finding row's control. So one review appends one event
  **per gap the active bundle declares** — same facts, same correlation id,
  different `control_id` — and each control's finding row is combined from
  exactly its own rules. The gap list is read off the tenant's active
  bundle, never duplicated here: a rule added to the bundle grows the event
  set (and the findings) without this module changing.
  """

  alias AshEnterprise.Compliance.EventLog

  @subject_type "user"

  @doc """
  Records the KYC facts a projected legacy row can supply.

  `projected` is an `AshEnterprise.Accounts.ProjectedUser`. Facts that need a
  human (identity confirmation, sanctions screening) are deliberately absent:
  their absence semantics make the finding read as `:unknown` rather than as
  a pass or a violation.

  The fact subject is the literal `"customer"` — the subject name the rule
  IR probes (`has(:customer, :status, :active)`), not the grain's
  `subject_id`. The grain identifies WHO is being evaluated; the fact
  triples are the evidence, and the rules address them by name.
  """
  @spec record_from_projection(AshEnterprise.Accounts.ProjectedUser.t(), keyword()) ::
          :ok | {:error, term()}
  def record_from_projection(projected, opts \\ []) do
    facts = [
      ["customer", "status", status_for(projected.legacy_state)],
      ["customer", "jurisdiction", "unknown"],
      ["customer", "email_domain", email_domain(projected.email)]
    ]

    record(projected.organization_id, projected.legacy_id, facts, opts)
  end

  @doc """
  Records a compliance officer's review: the screening and identity outcomes
  the legacy estate cannot supply.

  `facts` is a list of `[subject, "predicate", value]` triples, exactly the
  wire form the projector's fact extraction consumes. The reviewed subject's
  facts use the literal `"customer"`; other subjects are how the
  variable-join rule sees related entities —
  `["acct-7-1", "account_owner", "customer"]` names an account.
  """
  @spec record_review(String.t() | Ecto.UUID.t(), String.t() | integer(), list(), keyword()) ::
          :ok | {:error, term()}
  def record_review(organization_id, subject_id, facts, opts \\ []) do
    record(organization_id, subject_id, facts, opts)
  end

  defp record(organization_id, subject_id, facts, opts) do
    gaps = active_gaps!(organization_id)

    occurred_at =
      Keyword.get(opts, :occurred_at) || DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(gaps, fn gap ->
      metadata = %{
        "organization_id" => organization_id,
        "control_id" => gap,
        "subject_type" => @subject_type,
        "subject_id" => to_string(subject_id),
        "correlation_id" => Keyword.get(opts, :correlation_id),
        "facts" => facts
      }

      # `action:` on the PARAMS is the event's action attribute (:kyc_reviewed,
      # the thing the projector dispatches on); the keyword position would be
      # the Ash option that names the changeset action, which is not the same
      # thing and is a genuinely confusing way to lose an hour.
      Ash.create!(
        EventLog,
        %{
          record_id: Ecto.UUID.generate(),
          resource: :user,
          action: :kyc_reviewed,
          action_type: :update,
          data: %{},
          metadata: metadata,
          occurred_at: occurred_at
        },
        actor: Keyword.get(opts, :actor)
      )
    end)

    :ok
  rescue
    error -> {:error, error}
  end

  # The gaps the tenant's active bundle declares — read, not hardcoded, so
  # the event set follows the bundle. Raising on "no active bundle" rather
  # than silently appending nothing: a review that produces no events is a
  # KYC evaluation that never happened, and the projector's own error finding
  # cannot exist for a grain that was never written.
  #
  # Trusted machinery: the gap list is resolved before any event exists, so
  # there is no actor to act for; the read rides the package interface under
  # its documented trusted-machinery bypass.
  defp active_gaps!(organization_id) do
    case AshCompliance.Domain.active_policy_bundle(organization_id, authorize?: false) do
      {:ok, nil} ->
        raise """
        no active compliance policy bundle for organization #{organization_id}.
        Seed the KYC program first: mix ash_enterprise.compliance.seed
        """

      {:ok, bundle} ->
        {:ok, decoded} = AshRules.Ir.decode(bundle.rules_json)

        decoded.rules
        |> Enum.map(& &1.outcome.gap)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:error, error} ->
        raise error
    end
  end

  defp status_for("active"), do: "active"
  defp status_for("suspended"), do: "suspended"
  defp status_for(_other), do: "pending"

  defp email_domain(nil), do: nil

  defp email_domain(email) do
    email
    |> to_string()
    |> String.split("@")
    |> List.last()
    |> case do
      "" -> nil
      domain -> domain
    end
  end
end
