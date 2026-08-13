defmodule AshEnterprise.AI.Proposal do
  @moduledoc """
  A mutation an agent has proposed but **not** performed.

  This is the mechanism behind the human-in-the-loop half of
  `docs/manifesto/05-agents-are-users.md`. Policies answer *may this actor do
  this*; they cannot answer *did this actor actually ask for this*. Those differ
  precisely when a model is interpreting natural language, and the gap is where
  the confident-but-wrong mutation lives.

  So the model never holds the tool. It **plans**; the human **approves**; the
  application **executes**. A proposal is inert data until `execute/2` is called
  with a human's actor.

  ## Why this is not just "call the tool and show a diff"

  Two properties fall out of separating the plan from the execution:

    * The proposal can be **authorization-checked before it is shown**.
      `authorize/2` runs `Ash.can?` with the requesting human's actor, so a
      proposal the user could never perform is rejected at the point of display
      rather than after they approve it. Asking someone to confirm an action
      that will then fail is a bad experience and trains people to click through
      errors.
    * Execution is ordinary Ash code with the **human** as the actor. The audit
      entry therefore records the person who approved, not the agent — which is
      the truthful attribution, because the person is who decided.

  ## Deliberately narrow

  Only mutations the platform explicitly models as proposable can be built here.
  There is no generic "run this action with these params" constructor: that
  would make the safety of the flow depend on the model's choice of action name,
  which is exactly the property we are trying not to rely on.
  """

  @enforce_keys [:kind, :summary, :resource, :action, :params]
  defstruct [:kind, :summary, :resource, :action, :params, :details]

  @type t :: %__MODULE__{
          kind: atom(),
          summary: String.t(),
          resource: module(),
          action: atom(),
          params: map(),
          details: keyword()
        }

  alias AshEnterprise.Accounts
  alias AshEnterprise.Security

  require Ash.Query

  @doc """
  Builds a role-assignment proposal from names a human would use.

  Resolution runs **as the requesting actor**, so a user who cannot see a given
  user or role gets "not found" rather than a proposal referencing a record they
  have no business knowing exists. That is the same reasoning as Ash filtering
  reads instead of forbidding them.
  """
  def assign_role(actor, tenant, user_email, role_name) do
    with {:ok, user} <- find_user(actor, tenant, user_email),
         {:ok, role} <- find_role(actor, tenant, role_name) do
      {:ok,
       %__MODULE__{
         kind: :assign_role,
         summary: "Assign the #{role.name} role to #{user.email}",
         resource: Security.UserRole,
         action: :assign,
         params: %{user_id: user.id, role_id: role.id},
         details: [
           user: user.email,
           role: role.name,
           scope: "the user's own business unit"
         ]
       }}
    end
  end

  @doc """
  Can the requesting human actually perform this mutation?

  Checked before the confirmation is shown, not after it is approved.
  """
  def authorize(%__MODULE__{} = proposal, actor, tenant) do
    if Ash.can?({proposal.resource, proposal.action}, actor, tenant: tenant) do
      :ok
    else
      {:error,
       "You do not have permission to #{proposal.summary |> String.downcase()}. " <>
         "This proposal was not executed."}
    end
  end

  @doc """
  Performs the proposed mutation, with the approving human as the actor.

  Re-checks authorization rather than trusting the earlier `authorize/2`: the
  actor's roles could have changed between the proposal being shown and
  approved, and Ash would enforce it regardless -- doing it here makes the
  failure legible instead of an opaque policy error.
  """
  def execute(%__MODULE__{} = proposal, actor, tenant) do
    with :ok <- authorize(proposal, actor, tenant) do
      proposal.resource
      |> Ash.Changeset.for_create(proposal.action, proposal.params, actor: actor, tenant: tenant)
      |> Ash.create()
    end
  end

  # Callers are not all models sending plain strings: `email` is an
  # `Ash.CiString` when it comes from a loaded record, and `String.trim/1` has
  # no clause for it. Normalize once, here, rather than making every caller
  # remember which shape they hold.
  defp normalize(value), do: value |> to_string() |> String.trim()

  defp find_user(actor, tenant, email) do
    Accounts.User
    |> Ash.Query.filter(email == ^normalize(email))
    |> Ash.read_one(actor: actor, tenant: tenant)
    |> case do
      {:ok, nil} -> {:error, "No user found with the email #{inspect(email)}."}
      {:ok, user} -> {:ok, user}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp find_role(actor, tenant, name) do
    Security.Role
    |> Ash.Query.filter(name == ^normalize(name))
    |> Ash.read_one(actor: actor, tenant: tenant)
    |> case do
      {:ok, nil} -> {:error, "No role found named #{inspect(name)}."}
      {:ok, role} -> {:ok, role}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
