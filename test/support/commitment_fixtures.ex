defmodule AshEnterprise.Test.CommitmentFixtures do
  @moduledoc """
  SYNTHETIC fixtures for the commitment proposers
  (`AshEnterprise.Canonical.Commitments`): a sent message, a meeting with
  other people, and a stand-in for the in-zone model that answers from the
  text it is handed. Nothing here reaches a network; every address is on
  `example.test`.
  """

  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message}
  alias AshEnterprise.Canonical.Commitments.ModelExtractor
  alias AshEnterprise.Test.DailyFixtures

  @doc """
  Routes `ModelExtractor`'s request to `ScriptedExtractorModel`, which tells
  the calling process what it was sent. Restored on exit.
  """
  def scripted_model! do
    previous = Application.get_env(:ash_enterprise, ModelExtractor)

    Application.put_env(:ash_enterprise, ModelExtractor,
      downstream: __MODULE__.ScriptedExtractorModel
    )

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, ModelExtractor, previous),
        else: Application.delete_env(:ash_enterprise, ModelExtractor)
    end)

    :ok
  end

  @doc "A conversation in `system` with one message the user sent `minutes_ago`."
  def sent!(ctx, system, body, opts \\ []) do
    scope = opts[:scope] || DailyFixtures.scope!()
    sent_at = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :minutes_ago, 30), :minute)

    conversation =
      Conversation
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        Map.merge(owner(ctx.user), %{
          subject: "Synthetic thread",
          participants: %{},
          external_system: system,
          external_id: "conv-#{System.unique_integer([:positive])}",
          erasure_scope_id: scope.id
        }),
        tenant: ctx.tenant,
        authorize?: false
      )
      |> Ash.create!()

    message =
      Message
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        Map.merge(owner(ctx.user), %{
          body: body,
          sent_at: sent_at,
          direction: Keyword.get(opts, :direction, :outbound),
          external_system: system,
          external_id: "msg-#{System.unique_integer([:positive])}",
          conversation_id: conversation.id,
          erasure_scope_id: scope.id
        }),
        tenant: ctx.tenant,
        authorize?: false
      )
      |> Ash.create!()

    %{conversation: conversation, message: message, scope: scope}
  end

  @doc "A confirmed meeting with two other people that ended `minutes_ago`."
  def meeting!(ctx, title, opts \\ []) do
    scope = opts[:scope] || DailyFixtures.scope!()
    ends_at = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :minutes_ago, 60), :minute)

    attendees =
      for n <- 1..Keyword.get(opts, :attendees, 2) do
        person =
          DailyFixtures.person!(
            ctx,
            "guest-#{System.unique_integer([:positive])}@example.test",
            "Guest #{n}"
          )

        %{person_id: person.id, response_status: "accepted"}
      end

    CalendarEvent
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(ctx.user), %{
        title: title,
        starts_at: DateTime.add(ends_at, -30, :minute),
        ends_at: ends_at,
        status: :confirmed,
        external_system: "test",
        external_id: "evt-#{System.unique_integer([:positive])}",
        erasure_scope_id: scope.id,
        attendees: attendees
      }),
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp owner(user) do
    %{
      owner_id: user.id,
      owner_type: :user,
      owning_user_id: user.id,
      owning_business_unit_id: user.owning_business_unit_id
    }
  end

  defmodule ScriptedExtractorModel do
    @moduledoc """
    Stands in for ReqLLM behind `ModelExtractor` (`downstream:`): reports the
    prompt to the calling process as `{:extractor_prompt, prompt, opts}` and
    answers with one commitment when the message promises the Q3 deck, none
    otherwise. Synthetic text only.
    """

    def generate_object(_model, prompt, _schema, opts) do
      send(self(), {:extractor_prompt, prompt, opts})

      commitments =
        if prompt =~ "I'll send you the Q3 deck",
          do: [
            %{
              "action" => "Send Dana the Q3 deck",
              "quote" => "I'll send you the Q3 deck by Friday",
              "due" => "2026-10-23"
            }
          ],
          else: []

      {:ok,
       %ReqLLM.Response{
         id: "synthetic-#{System.unique_integer([:positive])}",
         model: "synthetic/in-zone",
         context: nil,
         object: %{"commitments" => commitments}
       }}
    end
  end
end
