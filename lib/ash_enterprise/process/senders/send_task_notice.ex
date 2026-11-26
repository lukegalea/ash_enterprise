defmodule AshEnterprise.Process.Senders.SendTaskNotice do
  @moduledoc """
  The task notice message: a person a process task is waiting on, or who was just added to
  one by an escalation, is sent a short message at their account's address, with a link to
  their task board (`/app/tasks`).

  The message names no task, record, organization or other person: it says that a task is
  waiting (or has expired) and where to look, and the person reads the rest after signing
  in. The address is the account's own, read when the notice is sent.

  Sent by `AshEnterprise.Process.TaskNotices`. Listed with the other account mail in
  `AshEnterprise.Governance.DataFlows`.
  """

  use AshEnterpriseWeb, :verified_routes

  import Swoosh.Email

  alias AshEnterprise.Mailer

  @doc "The message's subject line for a notice of `kind`."
  @spec subject(:remind | :escalated | :expired) :: String.t()
  def subject(:expired), do: "A task has expired"
  def subject(_kind), do: "A task is waiting for you"

  @doc """
  Sends the notice message for `kind` to `address`.

  `as:` says where the person stands on an escalated task. An escalation only adds people
  (`ash_bpmn` DESIGN.md §11.6): `:holder` keeps the task; `:added_while_held` can act on it
  only if its holder delegates it to them; `:can_act` (the default) can act on it now. No
  message says a task was passed to anyone.
  """
  @spec deliver(:remind | :escalated | :expired, String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def deliver(kind, address, opts \\ []) when is_binary(address) do
    link = url(~p"/app/tasks")
    line = line(kind, Keyword.get(opts, :as, :can_act))

    new()
    # The same literal sender as the account mail (`SendPasswordResetEmail`): a deployment
    # sets the real address with the rest of the mailer configuration.
    |> from({AshEnterprise.Brand.product_name(), "noreply@example.com"})
    |> to(address)
    |> subject(subject(kind))
    |> text_body("""
    #{line}

    Open your tasks here: #{link}
    """)
    |> html_body("""
    <p>#{line}</p>
    <p><a href="#{link}">Open your tasks here</a></p>
    """)
    |> Mailer.deliver()
  end

  defp line(:remind, _standing), do: "A task is waiting for you to act on it."

  defp line(:escalated, :holder),
    do:
      "A task you are holding has waited too long. More people have been added who can act " <>
        "on it if you delegate it to them."

  defp line(:escalated, :added_while_held),
    do:
      "A task a colleague is holding has waited too long. You have been added to the people " <>
        "who can act on it, and you can act on it if they delegate it to you."

  defp line(:escalated, :can_act),
    do: "A task has waited too long, and you have been added to the people who can act on it."

  defp line(:expired, _standing), do: "A task you could act on has expired."
end
