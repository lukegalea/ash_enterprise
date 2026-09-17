# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshEnterpriseWeb.ComplianceA2uiLive do
  @moduledoc """
  The compliance A2UI surfaces at `/app/compliance/*`.

  One LiveView per surface, each `use`-ing `AshA2ui.LiveRenderer` — the same
  shape as `AshEnterpriseWeb.A2uiLive`, in its own namespace because the
  compliance surfaces read foreign resources (`ash_compliance`) whose access
  is admin-shaped: the reads run with the signed-in actor, and the finding /
  evaluation resources have no public API surface, so these screens and
  `/admin` are the only doors.

  None of the compliance resources publish to PubSub, so these surfaces are
  not live-refreshing; a reload re-queries. That is the correct answer for
  audit surfaces rather than an omission — the projector, not the browser,
  is what keeps them current.
  """

  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2uiLive.Chrome

  defmodule Findings do
    @moduledoc "KYC findings: who breaches which control, and why."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.FindingUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]
    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])
    def render(assigns), do: Chrome.page(assigns)
  end

  defmodule Evaluations do
    @moduledoc "The append-only evaluation log: what the engine decided and why."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.ComplianceEvaluationUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]
    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])
    def render(assigns), do: Chrome.page(assigns)
  end

  defmodule Bundles do
    @moduledoc "Compiled policy bundles and their lifecycle."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.PolicyBundleUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]
    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])
    def render(assigns), do: Chrome.page(assigns)
  end

  defmodule RuleSets do
    @moduledoc "Rule set revisions: layers, lifecycle, content hashes."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.RuleSetRevisionUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]
    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])
    def render(assigns), do: Chrome.page(assigns)
  end

  defmodule Catalogs do
    @moduledoc "Compliance catalogs."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.CatalogUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]
    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])
    def render(assigns), do: Chrome.page(assigns)
  end

  defmodule Profiles do
    @moduledoc "Tailoring profiles."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.ProfileUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]
    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])
    def render(assigns), do: Chrome.page(assigns)
  end
end
