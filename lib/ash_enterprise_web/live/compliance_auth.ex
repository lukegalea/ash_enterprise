# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshEnterpriseWeb.ComplianceAuth do
  @moduledoc """
  The door in front of the compliance surfaces (`/app/compliance/*`).

  ## Why a door, and not policies

  The fourteen `ash_compliance` resources cannot carry this application's
  policy block: Spark builds policies into a resource at the resource's own
  compile time, and those resources are the package's, not ours — unlike the
  `ash_bpmn` resources, which ship as macros the host instantiates on
  `AshEnterprise.Platform.Resource` (ADR 0009) and so inherit the union of
  grants wholesale. ADR 0035 records what would change that.

  What we *can* do, and what this module does, is enforce the same grant the
  policies would: the actor must hold a role granting **read on the compliance
  finding resource** — the exact `(role, privilege, depth)` tuple the derived
  privilege catalogue creates for `AshCompliance.Resources.Finding` and the
  seeded Administrator role picks up. Behind the door, every surface runs its
  reads with the signed-in actor, so the row-level answer stays the resource's
  own; and the one compliance resource this application owns outright —
  `AshEnterprise.Compliance.EventLog` — carries the policy block for real.
  """

  use AshEnterpriseWeb, :verified_routes

  alias AshEnterprise.Security.ActorContext

  # The resource whose read privilege gates the compliance door. Any of the
  # fourteen would do — the privilege catalogue derives one per resource — and
  # the finding is named because it is the surface the compliance office lives
  # on. The a2ui surfaces behind this gate run their reads under this actor,
  # so a grant that reaches no rows renders an empty screen, not an error.
  @gate_resource AshCompliance.Resources.Finding

  def on_mount(:compliance_grant_required, _params, _session, socket) do
    if authorized?(socket.assigns[:current_user]) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/demo")}
    end
  end

  @doc """
  Whether this actor may open a compliance surface: a system actor, or one
  holding a read grant on the finding resource at any depth.
  """
  def authorized?(nil), do: false

  def authorized?(actor) do
    context = ActorContext.for_actor(actor)

    if context.system? do
      true
    else
      grant = ActorContext.grant(context, @gate_resource, :read)

      grant.global? or grant.basic? or MapSet.size(grant.business_unit_ids) > 0
    end
  end
end
