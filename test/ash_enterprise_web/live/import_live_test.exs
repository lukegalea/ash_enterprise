defmodule AshEnterpriseWeb.ImportLiveTest do
  @moduledoc """
  The import wizard driven through the actual LiveView: upload → parse →
  map (deterministic AI proposal) → activate → run → the batch lands rows
  in the steward queue. The queue's own decisions are MdmStewardUI's tested
  territory; this suite stops at "the candidate and the new golden exist".
  Every write runs as the signed-in person: one without a grant on mappings
  cannot draft one.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup %{conn: conn} do
    Seeder.seed_platform_organization()
    AshEnterprise.Mdm.Banding.publish_seed_bands!(platform_org())

    publish_steward_definition()

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Import #{System.unique_integer([:positive])}",
        unique_name: "import-#{System.unique_integer([:positive])}"
      )

    seed_rule_set!(organization.id, admin)
    golden_person!(organization.id, admin, "Ann Existing", "ann@x.io")

    %{conn: sign_in(conn, admin), org: organization.id, admin: admin}
  end

  defp platform_org, do: Seeder.seed_platform_organization().id

  defp publish_steward_definition do
    alias AshEnterprise.Bpmn.Definition

    xml = File.read!("priv/bpmn/mdm_steward_review.bpmn")

    definition =
      Definition.create!(%{key: "mdm.steward_review", name: "MDM steward review", xml: xml},
        actor: AshEnterprise.Platform.SystemActor.process(),
        tenant: platform_org()
      )

    Definition.publish!(definition,
      actor: AshEnterprise.Platform.SystemActor.process(),
      tenant: platform_org()
    )
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp seed_rule_set!(org, admin) do
    rules = [
      %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
      %{
        "name" => "name_fuzzy",
        "kind" => "fuzzy",
        "field" => "name",
        "algorithm" => "levenshtein",
        "weight" => 0.5
      }
    ]

    AshEnterprise.Mdm.MatchRuleSet
    |> Ash.Changeset.for_create(:draft, %{
      golden_resource: "AshEnterprise.Canonical.Person",
      rules: rules
    })
    |> Ash.create!(tenant: org, authorize?: false)
    |> Ash.Changeset.for_update(:activate, %{}, tenant: org, actor: admin)
    |> Ash.update!(tenant: org, actor: admin)
  end

  defp golden_person!(org, admin, name, email) do
    Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: name,
      email: email,
      owner_id: admin.id,
      owning_business_unit_id: admin.owning_business_unit_id
    })
    |> Ash.create!(tenant: org, authorize?: false)
  end

  @csv """
  Email,Full Name,Notes
  ann@x.io,Ann Existing-Smith,met at conference
  nadia@x.io,Nadia New,webinar signup
  """

  defp upload_csv(view) do
    upload =
      file_input(view, "#import-upload-form", :csv, [
        %{name: "contacts.csv", content: @csv, type: "text/csv"}
      ])

    render_upload(upload, "contacts.csv")

    view
    |> element("#import-upload-form")
    |> render_submit()
  end

  test "upload → propose → activate → run lands the review candidate and the new golden", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, "/app/mdm/import")

    html = upload_csv(view)

    assert html =~ "Email"
    assert html =~ "Full Name"
    assert html =~ "Notes"

    view |> element("#propose-btn") |> render_click()
    assert render(view) =~ "AI proposal loaded"

    # One editor edit through the DOM: the mapping editor round-trips the
    # form, merged with (not replacing) the proposal.
    view
    |> element("#mapping-editor")
    |> render_change(%{"rules" => %{"Full Name" => %{"target" => "name"}}})

    # The deterministic floor: the email and name columns map to the
    # Person's attributes; Notes stays unmapped.
    assert has_element?(
             view,
             "#rule-Email select[name='rules[Email][target]'] option[value='email'][selected]"
           )

    assert has_element?(
             view,
             "#rule-Full\\ Name select[name='rules[Full Name][target]'] option[value='name'][selected]"
           )

    view |> element("#validate-activate-btn") |> render_click()
    assert render(view) =~ "Mapping activated"

    view |> element("#run-batch-btn") |> render_click()
    assert render(view) =~ "Running"

    Oban.drain_queue(queue: :mdm, with_safety: false)
    Oban.drain_queue(queue: :bpmn, with_safety: false)
    send(view.pid, :tick)

    html = render(view)
    assert html =~ "Import finished"
    assert html =~ "review"

    # The finished run links the batch on the import-batch board.
    batch = AshEnterprise.Mdm.ImportBatch |> Ash.read_one!(tenant: org, authorize?: false)
    assert has_element?(view, "#go-batch-link[href='/app/r/mdm_batches/#{batch.id}']")

    # The fuzzy match awaits a steward; the genuinely new row is its own
    # golden (the queue decision itself is MdmStewardUI's territory).
    candidate =
      AshEnterprise.Mdm.MatchCandidate
      |> Ash.Query.filter(band == ^:review and status == ^:pending)
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert candidate != nil

    assert Person
           |> Ash.Query.filter(email == ^"nadia@x.io")
           |> Ash.exists?(tenant: org, authorize?: false)
  end

  test "an existing active mapping is selectable and runs end to end", %{
    conn: conn,
    org: org,
    admin: admin
  } do
    mapping = activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    {:ok, view, _html} = live(conn, "/app/mdm/import")
    upload_csv(view)

    assert render(view) =~ mapping.stream

    view
    |> element("input[phx-value-id='#{mapping.id}']")
    |> render_click()

    assert has_element?(view, "#run-batch-btn")

    view |> element("#run-batch-btn") |> render_click()

    Oban.drain_queue(queue: :mdm, with_safety: false)
    Oban.drain_queue(queue: :bpmn, with_safety: false)
    send(view.pid, :tick)

    assert render(view) =~ "Import finished"

    assert AshEnterprise.Mdm.MatchCandidate
           |> Ash.Query.filter(band == ^:review and status == ^:pending)
           |> Ash.exists?(tenant: org, authorize?: false)
  end

  test "an unmapped golden attribute without a because is refused at activation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/mdm/import")
    upload_csv(view)

    # Map Email with the `unmapped` operator but no because: total
    # accounting's explicit refusal.
    view
    |> element("#mapping-editor")
    |> render_change(%{"rules" => %{"Email" => %{"target" => "email", "op" => "unmapped"}}})

    view |> element("#validate-activate-btn") |> render_click()

    html = render(view)
    assert html =~ "Validation refused"
    assert html =~ "unmapped_without_because"

    # The editor stays: the person fixes the mapping, the machine never
    # activates.
    assert has_element?(view, "#validate-activate-btn")
  end

  test "a person without a grant on mappings cannot draft one", %{org: org, admin: admin} do
    member =
      AshEnterprise.Test.DailyFixtures.member!(
        %{tenant: org, user: admin},
        "No mapping grants",
        []
      )

    {:ok, view, _html} = live(sign_in(build_conn(), member.user), "/app/mdm/import")
    upload_csv(view)

    view
    |> element("#mapping-editor")
    |> render_change(%{
      "rules" => %{
        "Email" => %{"target" => "email", "op" => "trim"},
        "Full Name" => %{"target" => "name", "op" => "identity"}
      }
    })

    view |> element("#validate-activate-btn") |> render_click()

    assert render(view) =~ "Mapping refused"

    # Nothing was drafted on their behalf.
    refute AshEnterprise.Mdm.Mapping |> Ash.exists?(tenant: org, authorize?: false)
  end

  test "a person without a grant on mappings gets no AI draft written for them", %{
    org: org,
    admin: admin
  } do
    member =
      AshEnterprise.Test.DailyFixtures.member!(%{tenant: org, user: admin}, "No grants", [])

    {:ok, view, _html} = live(sign_in(build_conn(), member.user), "/app/mdm/import")
    upload_csv(view)

    view |> element("#propose-btn") |> render_click()

    assert render(view) =~ "Proposal failed"
    refute AshEnterprise.Mdm.Mapping |> Ash.exists?(tenant: org, authorize?: false)
    refute AshEnterprise.Mdm.MappingProposal |> Ash.exists?(tenant: org, authorize?: false)
  end

  test "a person who may not open a batch lands no rows", %{org: org, admin: admin} do
    mapping = activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    # They may see and pick the mapping, and nothing more.
    member =
      AshEnterprise.Test.DailyFixtures.member!(%{tenant: org, user: admin}, "Mapping reader", [
        {AshEnterprise.Mdm.Mapping, :read, :global}
      ])

    {:ok, view, _html} = live(sign_in(build_conn(), member.user), "/app/mdm/import")
    upload_csv(view)

    view |> element("input[phx-value-id='#{mapping.id}']") |> render_click()
    view |> element("#run-batch-btn") |> render_click()

    assert render(view) =~ "Import refused"
    refute AshEnterprise.Mdm.SourceRecord |> Ash.exists?(tenant: org, authorize?: false)
    refute AshEnterprise.Mdm.ImportBatch |> Ash.exists?(tenant: org, authorize?: false)
  end
end
