defmodule AshEnterprise.Bpmn.Subscription.Actions.InstallPack do
  @moduledoc """
  Runs `install_pack`: reads the named pack from `priv/packs/` and installs it into the
  call's tenant as drafts, as the call's actor (`AshEnterprise.Bpmn.Packs`).

  The action is human-only, so neither a system actor nor an automation principal nor
  anything an engine marks installs a pack, and the definitions and subscriptions it creates
  are authorized by the installing person's own grants.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Bpmn.Packs

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with {:ok, pack} <- Packs.load(input.arguments.pack) do
      Packs.install(pack, opts)
    end
  end
end
