defmodule AshEnterpriseWeb.Decisions.TryLive do
  @moduledoc """
  Try a decision version against sample inputs before publishing it.

  The page is `AshDecisions.Web.TryLive`: pick a version (the draft or any published one),
  type a value for each declared input, and see the answer, which rules matched and the hit
  policy that reduced them. A trial records nothing (`AshDecisions.Trial`).

  Every event re-reads the chosen version as the signed-in person, in their tenant, through
  the definition's read policy, rather than trusting an id or struct held in the socket. A
  version the person may not read, including any version of another tenant's decision, is
  refused the same way a missing one is.

  This application keeps the route (`/app/decisions/:key/try`, reached from the decision
  catalogue), the layout around the page, the link back to the catalogue, and the French:
  the page's words are in the `ash_decisions` Gettext domain.
  """

  use AshDecisions.Web.TryLive,
    domain: AshEnterprise.Decisions,
    actor: {AshEnterpriseWeb.Bpmn.Helpers, :current_actor, []},
    gettext: AshEnterpriseWeb.Gettext

  use Gettext, backend: AshEnterpriseWeb.Gettext
  use AshEnterpriseWeb, :verified_routes

  alias AshEnterpriseWeb.Layouts

  # The package renders the page; this application puts its own layout around it.
  defoverridable render: 1

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page={assigns[:page]}
      current_scope={assigns[:current_scope]}
      width="max-w-4xl"
    >
      <div class="space-y-6">
        {super(assigns)}

        <.link navigate={~p"/app/decisions"} class="text-sm underline" id="decision-try-back">
          {dgettext("default", "Every decision")}
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
