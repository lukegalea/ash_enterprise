defmodule AshEnterprise.Assistant.Tools.Proposals do
  @moduledoc """
  The proposal tools' one implementation (`AshEnterprise.Assistant.Propose`):
  build the `AshEnterprise.AI.Proposal` as the person, pre-check it with
  `Ash.can?`, and answer the model with the proposal's summary and its wire
  form (`Proposal.to_wire/1`). Nothing is written.

  A name that does not resolve, or a proposal the person could not carry out,
  is a refusal the model reads — never a guess.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.AI.Proposal
  alias AshEnterprise.Assistant.Lookups.Support

  @impl true
  def run(input, opts, context) do
    Support.gated(input, context, fn read_opts ->
      actor = read_opts[:actor]
      tenant = read_opts[:tenant]

      with {:ok, proposal} <- build(opts[:kind], input.arguments, actor, tenant),
           :ok <- Proposal.authorize(proposal, actor, tenant) do
        {:ok,
         Support.compact(%{
           "proposed" => proposal.summary,
           "proposal" => Proposal.to_wire(proposal),
           "effect" => proposal.details[:effect],
           "status" => status(proposal.kind)
         })}
      else
        {:error, message} when is_binary(message) -> Support.refused("Not proposed: " <> message)
        {:error, _other} -> Support.refused("Not proposed: that could not be resolved.")
      end
    end)
  end

  defp status(:draft_reply),
    do:
      "Waiting for the person to confirm it on screen. Nothing is stored yet, and the " <>
        "draft is never sent, now or later: say you proposed a draft for them to save."

  defp status(kind) when kind in [:decide_task, :steward_verdict],
    do:
      "Waiting for the person to confirm it on screen. Nothing is decided yet: say what " <>
        "you proposed and what confirming it will do."

  defp status(_kind),
    do:
      "Waiting for the person to confirm it on screen. Nothing has happened yet: " <>
        "say what you proposed and that it runs when they confirm."

  defp build(:task, %{change: :add} = args, actor, tenant),
    do: Proposal.create_task(actor, tenant, args[:title] || "", args[:due])

  defp build(:task, %{change: :done} = args, actor, tenant) do
    case args[:title] do
      blank when blank in [nil, ""] -> {:error, "say which action item: its id or its title"}
      task -> Proposal.complete_task(actor, tenant, task)
    end
  end

  defp build(:reply, args, actor, tenant),
    do: Proposal.draft_reply(actor, tenant, args.conversation, args.text)

  defp build(:sync, args, actor, tenant),
    do: Proposal.sync_now(actor, tenant, args[:account])

  defp build(:decision, %{on: :task} = args, actor, tenant) do
    if args.decision in [:approve, :reject],
      do: Proposal.decide_task(actor, tenant, args[:target], args.decision, args[:comment]),
      else: {:error, "a task is decided with approve or reject"}
  end

  defp build(:decision, %{on: :duplicate} = args, actor, tenant),
    do: Proposal.steward_verdict(actor, tenant, args[:target], verdict(args.decision))

  # A duplicate's approve is its merge, its reject keeping them apart.
  defp verdict(:approve), do: :merge
  defp verdict(:reject), do: :keep_separate
  defp verdict(decision), do: decision
end
