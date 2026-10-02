defmodule AshEnterprise.SystemOne.Checks.PersonActor do
  @moduledoc """
  True when the actor is a person — a real user row — and nothing else.

  A system actor of any name is refused, including `replay` and `ai`. The
  `ai` refusal is already structural (`AshEnterprise.Security.Checks.SystemActor`
  refuses it too, and an empty actor context fails every grant path), but
  this check carries its own refusal so a policy can require a person
  *positively* rather than by enumerating everything that is not one
  (ADR 0043, AST-136).

  Used where the record's meaning depends on a human: a human verdict's
  reviewer is the author of record (RFC v0 §7.3), so a verdict created by
  anything without a user row would be a judgement nobody made.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a person (a user row, never a system actor)"

  @impl true
  def match?(%AshEnterprise.Accounts.User{}, _authorizer, _opts), do: true
  def match?(_actor, _authorizer, _opts), do: false
end
