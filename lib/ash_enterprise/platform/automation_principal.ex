defmodule AshEnterprise.Platform.AutomationPrincipal do
  @moduledoc """
  A named non-human principal that is governed like a person (ADR 0043): its authority
  comes only from grant rows, never from a bypass.

  ## Named like a system actor, governed like a user

  The list is closed and compile-time, for the same reason
  `AshEnterprise.Platform.SystemActor`'s is: the non-human actors in this system should
  be auditable, and nobody should be able to mint one at runtime. Adding a principal is
  a reviewed change to this file.

  Unlike a system actor, an automation principal is **not** subject to the `SystemActor`
  bypass. What it may do is a set of roles assigned to it per tenant
  (`AshEnterprise.Security.AutomationRole`), resolved into an
  `AshEnterprise.Security.ActorContext` the way a person's roles are. With no rows, it
  can do nothing.

  ## Acting for a person

  An automation principal runs work a person asked for. The person must hold the start
  grant for the agent they ask it to run for (`AshEnterprise.Security.AgentStartGrant`,
  RFC 8693's `may_act`), and the work runs on the **intersection** of the two contexts:
  only what both the principal's grants and the person's allow
  (`AshEnterprise.Security.ActorContext.intersect/2`). Both are rebuilt from grant rows
  at every claim (`AshEnterprise.Execution.Identity`), so revoking either the person's
  role, the principal's role or the start grant stops the work before it runs.

  Work nobody asked for (a schedule, a process start) needs an agent version published
  as requesterless, which does not exist yet; until it does, an automation principal
  never runs without a person.

  ## The actor

  A person asks for automation work with `start/3`, which marks their own actor; they
  remain the actor of the request. The work itself runs as this struct, built by the
  identity at the claim: `name` is the principal, `id` the person it acts for (so what
  it creates is theirs, and `created_by_id` names them), and `agent` the agent. Its
  authority is the attached context and nothing else; the audit log records `name` as
  `automation_principal` beside the person (`AshEnterprise.Platform.Correlation`).
  """

  alias AshEnterprise.Security.ActorContext

  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          id: Ash.UUID.t() | nil,
          agent: String.t() | nil,
          __ash_enterprise_context__: ActorContext.t() | nil
        }

  # `__ash_enterprise_context__` is where `ActorContext.attach/2` puts the authority:
  # declared so that a principal with none is a principal with none, not a missing key.
  defstruct [:name, :description, :id, :agent, :__ash_enterprise_context__]

  @principals %{
    evaluator:
      "Runs agent evaluations: suite cases and shadow runs (ADR 0058). Its roles are " <>
        "assigned only in the tenant evaluations run in, so a case reads nothing " <>
        "elsewhere, and what a case asks for is answered from its fixtures, never run.",
    evidence_admitter:
      "Admits a judgment's evidence when a calibrated band table says to (ADR 0041, ADR " <>
        "0043). What it may admit is the roles a tenant assigns it, per question family; " <>
        "with none, every observation goes to a person."
  }

  @start_key :automation_start

  for {name, description} <- @principals do
    @doc "The `#{name}` automation principal: #{description}"
    def unquote(name)(), do: %__MODULE__{name: unquote(name), description: unquote(description)}
  end

  @doc "Every automation principal."
  @spec all() :: [t()]
  def all, do: Enum.map(names(), &apply(__MODULE__, &1, []))

  @doc "The names of every automation principal."
  @spec names() :: [atom()]
  def names, do: @principals |> Map.keys() |> Enum.sort()

  @doc """
  The principal named `name`, an atom or its string form. Never creates an atom: a
  string that names no principal is `:error`.
  """
  @spec fetch(atom() | String.t()) :: {:ok, t()} | :error
  def fetch(name) when is_atom(name) do
    if Map.has_key?(@principals, name), do: {:ok, apply(__MODULE__, name, [])}, else: :error
  end

  def fetch(name) when is_binary(name) do
    case Enum.find(names(), &(Atom.to_string(&1) == name)) do
      nil -> :error
      found -> fetch(found)
    end
  end

  def fetch(_name), do: :error

  @doc """
  Marks `person_actor` as asking for work to run as the automation principal `name`, for
  the agent `agent`. The person stays the actor of the request; the request names the
  principal, and refuses unless the person holds the start grant for `agent`.
  """
  @spec start(struct(), atom(), String.t()) :: struct()
  def start(person_actor, name, agent) when is_atom(name) and is_binary(agent) do
    Ash.Resource.put_metadata(person_actor, @start_key, %{name: name, agent: agent})
  end

  @doc "What `start/3` marked on `actor`, or `nil` when it asks for nothing but itself."
  @spec requested(term()) :: %{name: atom(), agent: String.t()} | nil
  def requested(%{__metadata__: metadata}), do: Map.get(metadata, @start_key)
  def requested(_actor), do: nil

  @doc """
  The actor to run as: `principal` acting for the person `person_id` and the agent
  `agent`, with `context` (already the intersection) as its whole authority.
  """
  @spec acting(t(), Ash.UUID.t(), String.t() | nil, ActorContext.t()) :: t()
  def acting(%__MODULE__{} = principal, person_id, agent, %ActorContext{} = context) do
    ActorContext.attach(%{principal | id: person_id, agent: agent}, context)
  end

  @doc "The value the audit log records for `principal`."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{name: name}), do: Atom.to_string(name)
end
