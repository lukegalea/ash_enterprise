# The Elixir half of scripts/provenance-demo.sh: fills the demo tenant a second time to prove
# the seed is idempotent, then walks the "where did this value come from" demo steps through
# the one code interface (`AshEnterprise.Provenance.explain/2`), each as the person the step
# names. Run by the shell script (`mix run`), never on its own: it reads the instance's
# database from DB_NAME, PGHOST and PGPORT.
#
# Every check raises with what it expected and what it saw, so a broken step stops the run.

defmodule ProvenanceDemo do
  @moduledoc false

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Flags
  alias AshEnterprise.Platform.DemoTenant
  alias AshEnterprise.Provenance
  alias AshEnterprise.Provenance.DemoData

  def run do
    organization = DemoTenant.find() || raise "the demo tenant is not provisioned"
    tenant = organization.id

    admin =
      AshEnterprise.Accounts.User
      |> Ash.Query.filter(email == ^DemoTenant.admin_email())
      |> Ash.read_one!(authorize?: false)

    handles = idempotent!(tenant, admin)

    reader = DemoData.actor!(DemoData.reader_email(), tenant)
    viewer = DemoData.actor!(DemoData.viewer_email(), tenant)

    why_on_a_title!(reader, tenant, handles)
    why_on_a_derived_value!(reader, tenant, handles)
    why_on_a_judged_fact!(reader, tenant, handles)
    why_as_a_viewer_without_the_source!(viewer, tenant, handles)
    why_through_the_assistant!(reader, viewer, tenant, handles, admin)
    why_on_a_recipe_written_value!(reader, tenant, handles, admin)
  end

  # --- steps ---------------------------------------------------------------------------------

  # The seed finds each row before it makes it: a second fill returns the same rows and writes
  # nothing to the audit log.
  defp idempotent!(tenant, admin) do
    first = DemoData.populate(tenant, admin)
    events = event_count(tenant)
    second = DemoData.populate(tenant, admin)

    expect!(second == first, "a second fill returns the same rows", first, second)
    expect!(event_count(tenant) == events, "a second fill writes no audit event", events, event_count(tenant))
    pass("seed: a second fill finds every row and writes nothing")
    first
  end

  # Demo step 1: Why on a task title names the write that set it, who made it and the
  # correlation id to follow it by. Its plan names the later write.
  defp why_on_a_title!(reader, tenant, handles) do
    {:ok, %{explanation: explanation, correlation_ids: correlation_ids}} =
      explain(reader, tenant, "task", handles.task, "title")

    generated = step!(explanation, :was_generated_by)
    expect!(generated.summary == "create capture", "the title's write", "create capture", generated.summary)

    associated = step!(explanation, :was_associated_with)
    writer = DemoData.writer_email()
    expect!(associated.agent_label == writer, "the title's writer", writer, associated.agent_label)

    expect!(
      is_binary(Map.get(correlation_ids, generated.activity)),
      "the title's write carries a correlation id",
      "a binary",
      correlation_ids
    )

    {:ok, %{explanation: plan}} = explain(reader, tenant, "task", handles.task, "plan")
    planned = step!(plan, :was_generated_by)
    refute!(planned.summary == "create capture", "the plan was set by a later write: #{planned.summary}")
    pass("why on a task title: the write, its writer and its correlation id; the plan's own later write")
  end

  # Demo step 2: a derived field names the fields it is computed from, and each is explained.
  defp why_on_a_derived_value!(reader, tenant, handles) do
    {:ok, %{explanation: explanation}} = explain(reader, tenant, "task", handles.task, "lane")

    derived = Enum.filter(explanation.steps, &(&1.relation == :was_derived_from))
    antecedents = derived |> Enum.map(& &1.antecedent.attribute) |> Enum.sort()
    expect!(antecedents == ["plan", "status"], "the lane's antecedents", ["plan", "status"], antecedents)

    for field <- antecedents do
      expect!(
        Enum.any?(explanation.steps, &(&1.relation == :was_generated_by and &1.entity.attribute == field)),
        "the walk explains #{field}",
        "a write step",
        "none"
      )
    end

    pass("why on a derived field: lane from plan and status, each explained in turn")
  end

  # Demo step 3: a judged fact explains itself down to the document's atoms, and an atom that
  # has since been erased reads erased, with nothing else said of it.
  defp why_on_a_judged_fact!(reader, tenant, handles) do
    {:ok, %{explanation: kept}} = explain(reader, tenant, "fact", handles.clinician_facts.kept, "value")

    generated = step!(kept, :was_generated_by)
    expect!(generated.activity =~ "banding:", "the fact's admission", "a banding", generated.activity)
    expect!(step!(kept, :used).summary =~ "rule_showcase_search", "the matched rule", "rule_showcase_search", inspect(kept.steps))
    atoms = atom_steps(kept)
    expect!(length(atoms) == 2, "the fact cites two atoms", 2, length(atoms))
    expect!(kept.gaps == [], "the intact chain has no gap", [], kept.gaps)
    refute!(inspect(kept) =~ "Licence scan", "an atom's text appears in the answer")

    {:ok, %{explanation: erased}} = explain(reader, tenant, "fact", handles.clinician_facts.erased, "value")

    kinds = Enum.map(erased.gaps, & &1.kind)
    expect!(kinds == [:erased, :erased], "the shredded atoms read erased", [:erased, :erased], kinds)
    expect!(atom_steps(erased) == [], "no erased atom is named", [], atom_steps(erased))
    expect!(step!(erased, :used).summary =~ "rule_showcase_search", "the rule still answers", "the matched rule", "none")
    refute!(inspect(erased) =~ "Licence scan", "an erased atom's text appears in the answer")

    pass("why on a judged fact: band, matched rule, two atoms; the erased document's atoms read erased")
  end

  # Demo step 4: a person who may not read the source is told the value is not found, in the
  # words used for a value that does not exist.
  defp why_as_a_viewer_without_the_source!(viewer, tenant, handles) do
    for {type, id, attribute} <- [
          {"task", handles.task, "title"},
          {"fact", handles.clinician_facts.kept, "value"}
        ] do
      missing = Ash.UUID.generate()

      {:error, %Ash.Error.Invalid{} = hidden} = explain(viewer, tenant, type, id, attribute)
      {:error, %Ash.Error.Invalid{} = absent} = explain(viewer, tenant, type, missing, attribute)

      expect!(
        messages(hidden, id) == messages(absent, missing),
        "a hidden #{type} reads as a missing one",
        messages(absent, missing),
        messages(hidden, id)
      )
    end

    pass("a viewer without source read: the task and the fact are not found, as a missing id is")
  end

  # Demo step 5: the assistant's explain tool on /mcp, given the address of the title. The
  # `ont_why` flag is turned on for the demo tenant only, and offers the answer without
  # authorizing it: the reader gets the steps as rows, never the value, and the viewer, who has
  # no read grant, gets the one row an absent value gets.
  defp why_through_the_assistant!(reader, viewer, tenant, handles, admin) do
    admin_actor = DemoData.actor!(to_string(admin.email), tenant)
    address = "#{Provenance.base()}/task/#{handles.task}#title"

    {:error, off} = call_explain(reader, address)
    expect!(off =~ "not turned on", "the flag off offers nothing", "not turned on", off)

    Flags.set_flag!("ont_why", %{state: :on}, actor: admin_actor, tenant: tenant)

    {:rows, rows} = call_explain(reader, address)
    entries = Enum.filter(rows, &(&1["role"] == "entry"))
    expect!(entries != [], "the reader is answered with steps", "entry rows", rows)

    expect!(
      Enum.any?(entries, &(&1["kind"] == "was_generated_by")),
      "a step names the write that set the title",
      "was_generated_by",
      Enum.map(entries, & &1["kind"])
    )

    refute!(JSON.encode!(rows) =~ "Dana", "the title itself is in an answer")

    {:rows, [hidden]} = call_explain(viewer, address)
    {:rows, [absent]} = call_explain(viewer, "#{Provenance.base()}/task/#{Ash.UUID.generate()}#title")
    expect!(hidden["role"] == "missing", "a viewer without the grant gets the missing row", "missing", hidden)
    expect!(hidden["missing"] =~ "that you may read", "the missing row's words", "that you may read", hidden)

    mask = fn row -> String.replace(row["missing"], ~r/task\/[0-9a-f-]{36}/, "task/ID") end
    expect!(mask.(hidden) == mask.(absent), "a hidden value reads as an absent one", mask.(absent), mask.(hidden))

    pass("the assistant on /mcp: the reader gets steps and no value; the viewer gets what an absent value gets")
  end

  # Demo step 7: a value a recipe's step wrote names the principal, the person it acted for,
  # the dispatch and the standing grant it ran under, and never the person who caused the event.
  defp why_on_a_recipe_written_value!(reader, tenant, handles, admin) do
    title_task = recipe_task(tenant)
    expect!(title_task == handles.recipe_task, "the recipe's task", handles.recipe_task, title_task)

    {:ok, %{explanation: explanation, correlation_ids: correlation_ids}} =
      explain(reader, tenant, "task", handles.recipe_task, "title")

    behalf = step!(explanation, :acted_on_behalf_of)
    expect!(behalf.agent_label == "an automation principal (recipe_runner)", "the runner", "recipe_runner", behalf.agent_label)
    publisher = DemoData.publisher_email()
    expect!(behalf.on_behalf_of == publisher, "who the recipe acted for", publisher, behalf.on_behalf_of)
    expect!(behalf.activity == "dispatch:" <> handles.dispatch, "the dispatch", handles.dispatch, behalf.activity)

    used = step!(explanation, :used)
    expect!(used.entity.resource == "agent_start_grant", "the grant", "agent_start_grant", used.entity.resource)
    expect!(used.entity.id == handles.grant, "the grant's id", handles.grant, used.entity.id)

    # The rows the Why page and the tool show carry the publisher and the grant too.
    rows = Provenance.Why.rows(explanation, correlation_ids)
    behalf_row = Enum.find(rows, &(&1.relation == :acted_on_behalf_of))
    expect!(behalf_row[:on_behalf_of] == publisher, "the row's on behalf of", publisher, behalf_row[:on_behalf_of])
    grant_ref = "agent_start_grant:" <> handles.grant
    used_row = Enum.find(rows, &(&1.relation == :used))
    expect!(used_row[:from] == grant_ref, "the row's grant", grant_ref, used_row[:from])

    refute!(inspect(explanation) =~ to_string(admin.email), "the person who caused the event is named")
    pass("why on a recipe-written value: recipe_runner for the publisher, under the dispatch and its grant")
  end

  # --- plumbing ------------------------------------------------------------------------------

  defp explain(actor, tenant, type, id, attribute) do
    Provenance.explain("#{Provenance.base()}/#{type}/#{id}##{attribute}", actor: actor, tenant: tenant)
  end

  # The explain tool on the loopback instance, called with `actor`'s bearer token.
  defp call_explain(actor, address) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(actor)

    response =
      Req.post!("http://127.0.0.1:#{System.fetch_env!("PORT")}/mcp",
        auth: {:bearer, token},
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "explain", "arguments" => %{"input" => %{"address" => address}}}
        }
      )

    expect!(response.status == 200, "the /mcp status", 200, response.status)

    case response.body do
      %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} -> {:rows, text |> JSON.decode!() |> List.wrap()}
      %{"result" => %{"isError" => true} = result} -> {:error, JSON.encode!(result)}
    end
  end

  defp recipe_task(tenant) do
    AshEnterprise.Canonical.Task
    |> Ash.Query.filter(title == ^DemoData.recipe_task_title())
    |> Ash.read_one!(authorize?: false, tenant: tenant)
    |> Map.fetch!(:id)
  end

  defp event_count(tenant), do: Ash.count!(EventLog, authorize?: false, tenant: tenant)

  defp step!(explanation, relation) do
    case Enum.filter(explanation.steps, &(&1.relation == relation)) do
      [step] -> step
      steps -> raise "expected one #{relation} step, got #{length(steps)}: #{inspect(steps)}"
    end
  end

  defp atom_steps(explanation) do
    Enum.filter(explanation.steps, &(&1.relation == :was_derived_from and &1.antecedent.type == "addressed_atom"))
  end

  # What an error says, with the row's own id masked, so two refusals compare by wording.
  defp messages(error, id) do
    error.errors |> Enum.map(&Exception.message/1) |> Enum.map(&String.replace(&1, id, "<id>"))
  end

  defp expect!(true, _what, _expected, _got), do: :ok
  defp expect!(false, what, expected, got), do: raise("#{what}: expected #{inspect(expected)}, got #{inspect(got)}")

  defp refute!(false, _message), do: :ok
  defp refute!(true, message), do: raise(message)

  defp pass(message), do: IO.puts("PASS  #{message}")
end

ProvenanceDemo.run()
