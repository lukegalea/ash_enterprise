defmodule AshEnterprise.Journeys.Offboarding do
  @moduledoc """
  Offboarding, as the person who does it walks it: an administrator deactivates
  someone who is leaving, from the users surface.

  The browser tier walks it in English and French
  (`test/e2e/journeys/journeys_test.exs`), and only an approved passing run of it
  is published (`priv/journeys/`, `mix ash_journeys.approve`). What it says is
  what that run proved:

    * deactivating asks for confirmation first, and the journey shows the dialog;
    * the action is traced from the server's event to the `deactivate` action
      under one correlation id, and that correlation id wrote the audit row;
    * the person's account is inactive afterwards;
    * they are not disconnected at once: an open page of theirs stays until their
      next action, and that action sends them to sign in.

  `metadata` names the controls it is evidence for; only the evidence sink reads it.
  """

  use AshJourneys.Journeys,
    gettext: AshEnterpriseWeb.Gettext,
    surfaces: AshEnterprise.Journeys.Surfaces,
    personas: AshEnterprise.Journeys.Personas,
    world: AshEnterprise.Journeys.World

  journey :revoke_a_leavers_access do
    version(1)
    kind :how_to
    title "Revoke a leaver's access"
    goal("The person who is leaving can no longer use the app.")

    outcome(
      "Their account is inactive, and the next thing they do in the app sends them to sign in."
    )

    locales([:en, :fr])
    metadata controls: ["CC6.2", "CC6.3"]

    persona(:admin, :tenant_admin)
    persona(:leaver, :member)

    world(
      bind: [admin: {:tenant_admin, "admin"}, leaver: {:member, "dana"}],
      clock: ~U[2026-03-02 09:00:00Z],
      timestamps: [admin: [created_on: {0, :minute}], leaver: [created_on: {30, :minute}]]
    )

    step :leaver_is_signed_in, as: :leaver do
      open(:launcher)
      say("The person who is leaving is still signed in, with the app open.")
    end

    step :find_the_person, as: :admin do
      open(:users)
      say("Open %{surface} and find the person who is leaving.", surface: ui(:users))

      figure(:people,
        frame: :page,
        highlight: {:row, :leaver},
        mask: [{:as_of, width: "6rem"}]
      )
    end

    step :deactivate, as: :admin do
      row_action("table.deactivate", on: :leaver, confirm: true)

      say("Choose %{action} on their row, and confirm.",
        action: ui({:row_action, "table.deactivate"})
      )

      figure(:confirm, frame: :dialog)

      note(
        :warning,
        "They are not signed out at once: the next thing they do in the app sends them to sign in."
      )

      expect(
        trace: [:handle_event, {:ash_action, :deactivate}],
        one_correlation: true,
        audit: true
      )

      expect(record: {:leaver, lifecycle_status: :inactive})
      figure(:deactivated, frame: {:row, :leaver})
    end

    step :their_next_action_signs_them_out, as: :leaver do
      open(:launcher)
      expect(lands_on: :sign_in)
      say("The next time they open the app, they are sent to sign in.")
      figure(:sign_in, frame: :page)
    end
  end
end
