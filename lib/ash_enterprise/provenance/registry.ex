defmodule AshEnterprise.Provenance.Registry do
  @moduledoc """
  Which resource answers which address, and who answers first.

  The `<type>` token of an address (ADR 0078, section 1) is declared here,
  never derived from a module name, so renaming a module does not move an
  address: the token is part of a stable identity (every address and every
  trace reference that used it would break). Two tokens for one resource, or
  one token for two resources, fails compilation.

  The dispatch order (ADR 0078, section 4) is `explainers_for/2`: package
  explainers declared for the resource and field first, then the derived-value
  explainer, the audit explainer and the record columns. Package explainers
  (MDM statements, judged facts, decisions) are a later change; the slot is the
  empty `@package_explainers` list.
  """

  @pairs [
    {"task", AshEnterprise.Canonical.Task},
    {"person", AshEnterprise.Canonical.Person},
    {"account", AshEnterprise.Canonical.Account},
    {"credential", AshEnterprise.Credentialing.Credential},
    {"audit_event", AshEnterprise.Audit.EventLog},
    {"person_erasure", AshEnterprise.Erasure.PersonErasure},
    {"dispatch", AshEnterprise.Bpmn.Dispatch},
    {"agent_start_grant", AshEnterprise.Security.AgentStartGrant}
  ]

  # One token for two resources would answer one address two ways; two tokens
  # for one resource would make its past addresses dangle. Both are compile
  # errors: a declaration conflict, not a runtime discovery. `Map.new/2` keeps
  # the last of a duplicate, so the declaration itself is what is checked —
  # before any map can hide it.
  cond do
    length(Enum.uniq_by(@pairs, &elem(&1, 0))) != length(@pairs) ->
      raise ArgumentError, "two resources are registered under one type token"

    length(Enum.uniq_by(@pairs, &elem(&1, 1))) != length(@pairs) ->
      raise ArgumentError, "a resource is registered under two type tokens"

    true ->
      :ok
  end

  @tokens Map.new(@pairs)
  @resources Map.new(@pairs, fn {token, resource} -> {resource, token} end)

  # Package explainers declared for a resource and field (MDM statements,
  # judged facts, decisions): none yet. Each entry is
  # `{resource, field, module}` and runs before the generic explainers.
  @package_explainers []

  @doc "The resource a type token addresses."
  @spec resource(String.t()) :: {:ok, Ash.Resource.t()} | :error
  def resource(token), do: Map.fetch(@tokens, token)

  @doc "The type token a resource is addressed by."
  @spec token(Ash.Resource.t()) :: {:ok, String.t()} | :error
  def token(resource), do: Map.fetch(@resources, resource)

  @doc """
  The explainers that may answer for `field` of `resource`, in dispatch order.
  The first that does not pass answers (ADR 0078, section 4).
  """
  @spec explainers_for(Ash.Resource.t(), atom() | nil) :: [module()]
  def explainers_for(resource, field) do
    package =
      for {res, fld, mod} <- @package_explainers, res == resource, fld == field do
        mod
      end

    package ++
      [
        AshEnterprise.Provenance.Explainers.Derived,
        AshEnterprise.Provenance.Explainers.Audit,
        AshEnterprise.Provenance.Explainers.RecordColumns
      ]
  end
end
