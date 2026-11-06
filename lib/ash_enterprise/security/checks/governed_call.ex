defmodule AshEnterprise.Security.Checks.GovernedCall do
  @moduledoc """
  A grant path for a provider call made **on behalf of a governed invocation**
  (`AshAgent.Invocation`, ADR 0055): the call carries the invocation that governs it, so the
  governed act's own approval already stands behind it.

  The executor runs the act, and the reconciler runs its `reconcile_with` read, with
  `context.ash_agent` naming the invocation (`invocation_id`). This check matches exactly
  that: a generic action whose context names an invocation. It is how
  `AshEnterprise.Credentialing.RegistryApi` is reached by `activate_credential` and its
  reconcile without carrying any role grant, so no one can call the registry past the
  four-eyes approval.

  It is one more `authorize_if` in the union (an additive grant path, never a `forbid_if`),
  and it admits a person or an automation principal acting through an invocation: the
  invocation's own executing principal is checked where it matters, by
  `AshAgent.Validations.Governed` on the act itself. A context is only what the caller says,
  so this path is deliberately no stronger than "an invocation is named"; the act it serves
  verifies the invocation, its lease and its arguments before it ever reaches the registry.

  ## Never queries

  It reads the action input's context and nothing else.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the call carries the governed invocation it is made for"

  @impl true
  def match?(_actor, %{subject: %{context: %{ash_agent: %{invocation_id: id}}}}, _opts)
      when is_binary(id),
      do: true

  def match?(_actor, _context, _opts), do: false
end
