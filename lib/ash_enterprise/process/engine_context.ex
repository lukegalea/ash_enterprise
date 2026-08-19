defmodule AshEnterprise.Process.EngineContext do
  @moduledoc """
  Reading the tenant out of whatever the process engine hands a host callback.

  ## Why this exists

  `ash_bpmn` passes each of its three seams a context map documented as carrying `:tenant`.
  On some paths it is there and on others it is `nil`, and every one of the three callbacks was
  written assuming the first.

  The failures that produced were all the same shape and all several steps from the cause: a
  `UserRole` inserted with a null `organization_id` and rejected by a not-null constraint; a
  decision evaluation recorded against no tenant and therefore invisible to the tenant that
  caused it; a candidate query returning nobody, so a task nobody could claim. None of them
  said "no tenant".

  So the tenant is derived once, here, from the first of several things that knows it. Each
  fallback is a record the engine has already loaded, so this costs nothing and cannot be
  wrong: an instance, a task and a subject all belong to exactly one tenant by construction.

  A single place also means that if `ash_bpmn` later threads the tenant reliably, there is one
  function to simplify rather than three call sites to find.
  """

  @doc """
  The tenant this engine callback is acting for, or nil if genuinely nothing knows.

  Nil is worth distinguishing from a guess: a caller that gets nil should refuse rather than
  write a row with no tenant, which is the failure this module exists to prevent.
  """
  @spec tenant(map()) :: Ash.UUID.t() | nil
  def tenant(ctx) when is_map(ctx) do
    ctx[:tenant] ||
      organization_id(ctx[:instance]) ||
      organization_id(ctx[:task]) ||
      organization_id(ctx[:subject])
  end

  def tenant(_ctx), do: nil

  @doc """
  Standard options for a host action the engine is invoking.

  Always the platform's named process actor, never the actor the engine is carrying: that one
  is an `AshBpmn.SystemActor`, a struct this application's policy set has never heard of, so a
  host action called with it is simply forbidden — silently, as a process that stops.
  """
  @spec engine_opts(map(), keyword()) :: keyword()
  def engine_opts(ctx, extra \\ []) do
    [actor: AshEnterprise.Platform.SystemActor.process(), tenant: tenant(ctx)] ++ extra
  end

  defp organization_id(%{organization_id: id}) when not is_nil(id), do: id
  defp organization_id(_), do: nil
end
