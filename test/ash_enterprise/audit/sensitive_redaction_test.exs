defmodule AshEnterprise.Audit.SensitiveRedactionTest do
  @moduledoc """
  A `sensitive?` value never reaches the audit log, in any of its fields.

  The regression: `ash_events` nils sensitive values in an event's `data`, but
  not in `changed_attributes`, so the bcrypt hash `HashPasswordChange` sets on
  every registration was written into `audit_events`, a table that can never be
  cleaned. `AshEnterprise.Audit.Changes.RedactSensitive` closes it for every
  resource; these tests pin the cases that exist today.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.{Organization, User}
  alias AshEnterprise.Audit.{Chain, EventLog}
  alias AshEnterprise.Audit.Changes.RedactSensitive
  alias AshEnterprise.Canonical.Message
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.ActorContext

  @password "redaction-password-1234"
  @new_password "redaction-password-5678"

  describe "User.hashed_password" do
    test "registration records that the hash was set, never the hash" do
      user = register!()
      assert "$2" <> _ = user.hashed_password

      [event] = events(user.id, :register_with_password)

      assert Map.has_key?(event.changed_attributes, "hashed_password")
      assert event.changed_attributes["hashed_password"] == nil
      assert event.data["password"] == nil
      assert event.data["password_confirmation"] == nil

      refute_spelled_anywhere(user.hashed_password)
      refute_spelled_anywhere(@password)
      assert %{findings: []} = Chain.verify(nil)
    end

    test "a password change records neither the old nor the new hash" do
      user = register!()

      changed =
        user
        |> Ash.Changeset.for_update(
          :change_password,
          %{
            current_password: @password,
            password: @new_password,
            password_confirmation: @new_password
          },
          authorize?: false
        )
        |> Ash.update!()

      assert changed.hashed_password != user.hashed_password

      [event] = events(user.id, :change_password)
      assert event.changed_attributes["hashed_password"] == nil

      refute_spelled_anywhere(user.hashed_password)
      refute_spelled_anywhere(changed.hashed_password)
      refute_spelled_anywhere(@new_password)
    end
  end

  describe "LinkedAccount.connection_id and label" do
    test "a link records neither the connection id nor the label" do
      org = organization!()
      user = register!()
      connection_id = "conn-redaction-#{System.unique_integer([:positive])}"
      label = "redaction-label-#{System.unique_integer([:positive])}"

      linked =
        LinkedAccount.link!(
          %{provider_config_key: "google-calendar", connection_id: connection_id, label: label},
          actor: actor(user, org),
          tenant: org.id,
          authorize?: false
        )

      [event] = events(linked.id, :link)
      assert event.data["connection_id"] == nil
      assert event.data["label"] == nil
      assert event.data["provider_config_key"] == "google-calendar"

      refute_spelled_anywhere(connection_id)
      refute_spelled_anywhere(label)
    end
  end

  describe "the rule" do
    test "covers sensitive attributes and sensitive action arguments" do
      names = RedactSensitive.redacted_names(User, :register_with_password)

      assert :hashed_password in names
      assert :password in names
      assert :password_confirmation in names
      refute :email in names
    end

    test "keeps ash_cloak ciphertext, which ADR 0024 shreds by key" do
      names = RedactSensitive.redacted_names(Message, :create)

      refute :encrypted_body in names
      assert Ash.Resource.Info.attribute(Message, :encrypted_body).sensitive?
    end

    test "leaves an event for something that is not a resource alone" do
      assert RedactSensitive.redacted_names(:not_a_resource, :create) == []
      assert RedactSensitive.redacted_names(User, nil) |> Enum.member?(:hashed_password)
    end
  end

  defp register! do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "redaction-#{System.unique_integer([:positive])}@example.com",
        password: @password,
        password_confirmation: @password
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp organization! do
    unique = "redaction-#{System.unique_integer([:positive])}"

    Organization
    |> Ash.Changeset.for_create(:create, %{name: unique, unique_name: unique}, authorize?: false)
    |> Ash.create!()
  end

  defp actor(user, org) do
    ActorContext.attach(user, %ActorContext{
      user_id: user.id,
      organization_id: org.id,
      principal_ids: [user.id]
    })
  end

  defp events(record_id, action) do
    EventLog
    |> Ash.Query.filter(record_id == ^record_id and action == ^action)
    |> Ash.read!(authorize?: false)
  end

  # The whole table, as Postgres stores it: whatever the Elixir side decodes,
  # the hash is not in a row.
  defp refute_spelled_anywhere(fragment) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM audit_events
        WHERE strpos(data::text || changed_attributes::text || metadata::text, $1) > 0
        """,
        [fragment]
      )

    assert count == 0, "#{count} audit event(s) still spell #{inspect(fragment)}"
  end
end
