defmodule AshEnterpriseWeb.ImportLive do
  @moduledoc """
  The CSV import wizard (`/app/mdm/import`) — the producing half of the MDM
  demo flow, the UI face of the code path `CsImportFlowTest` drives:

  1. **Upload** — a CSV is kept as a file on the server
     (`AshEnterprise.Mdm.BulkImport`) and streamed once for its headers, a
     ten-row sample and its row count. The rows themselves never enter this
     process: up to the configured cap (50,000 by default) a file is accepted,
     and over it the file is refused before anything lands.
  2. **Mapping** — an existing active ingress mapping is picked, or a new
     one is drafted: per observed column a target/op/because row, with an AI
     proposal (`AshEnterprise.Mdm.Proposal`) as the first draft. Activation
     goes through the mapping's own person gate — the machine drafts, a
     person activates.
  3. **Run** — a batch opens (pinning the mapping's content hash), and the
     `BatchWorker` Oban job lands the file a chunk at a time, then stages →
     matches → bands. The view polls the job and shows the tally, and links
     the batch on the import-batch board (`/app/mdm/batches`), which lists
     any rows that did not land with their row numbers; review-banded
     matches end up in the steward queue at `/app/mdm`.

  Every write is the signed-in person's to authorize — proposing (the AI
  draft is written as them), drafting, validating and activating a mapping,
  opening the batch — so their grants decide. Landing the rows is the
  platform's own write (`Landing.land_row/4`, raw source records), so it runs
  only in the worker of a batch the person was allowed to open; a refusal
  opens no batch and lands nothing.

  Mapping reads happen in `handle_params` (iron law #01: no DB work in
  mount — the dead render is crawler HTML).
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Mdm.{BulkImport, ImportBatch, Mapping, Proposal, StagedRecord}
  alias AshEnterprise.Security.ActorContext

  require Ash.Query

  @staged_statuses [:staged, :matched, :admitted, :review, :omitted, :created, :merged, :rejected]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import CSV")
     |> assign(:step, :upload)
     |> assign(:upload_id, nil)
     |> allow_upload(:csv,
       accept: ~w(.csv),
       max_entries: 1,
       max_file_size: BulkImport.max_file_size()
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    actor = socket.assigns.current_user
    tenant = ActorContext.tenant(actor)

    mappings =
      Mapping
      |> Ash.Query.filter(direction == ^:ingress and status == ^:active)
      |> Ash.read!(tenant: tenant, actor: actor)

    {:noreply, assign(socket, :mappings, mappings)}
  end

  # -- upload step -----------------------------------------------------------

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("preview", _params, socket) do
    # A new preview replaces the file an earlier one stored.
    BulkImport.discard(socket.assigns.upload_id)

    with {:ok, upload_id} <- store_csv(socket),
         {:ok, summary} <- inspect_or_discard(upload_id) do
      %{headers: headers, sample: sample, row_count: row_count} = summary

      {:noreply,
       socket
       |> assign(:upload_id, upload_id)
       |> assign(:headers, headers)
       |> assign(:row_count, row_count)
       |> assign(:sample_rows, sample)
       |> assign(:observed_schema, Map.new(headers, &{&1, %{}}))
       |> assign(:samples, samples(headers, sample))
       |> assign(
         :rules,
         Map.new(headers, &{&1, %{"target" => "", "op" => "identity", "because" => ""}})
       )
       |> assign(:mapping_id, nil)
       |> assign(:slug, "upload-" <> Integer.to_string(System.unique_integer([:positive])))
       |> assign(:step, :mapping)}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:upload_id, nil)
         |> put_flash(:error, "Could not read the CSV: #{upload_error(reason)}")}
    end
  end

  # -- mapping step ----------------------------------------------------------

  def handle_event("select-mapping", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:mapping_id, id) |> assign(:step, :mapping)}
  end

  def handle_event("draft-new", _params, socket) do
    {:noreply, assign(socket, :mapping_id, nil)}
  end

  def handle_event("slug-change", %{"slug" => slug}, socket) do
    {:noreply, assign(socket, :slug, slug)}
  end

  def handle_event("rule-change", params, socket) do
    case params["rules"] do
      rules when is_map(rules) ->
        # The form posts every row; merge so propose-loaded state survives.
        merged =
          Map.merge(socket.assigns.rules, rules, fn _field, current, incoming ->
            %{
              "target" => incoming["target"] || current["target"] || "",
              "op" => incoming["op"] || current["op"] || "identity",
              "because" => incoming["because"] || current["because"] || ""
            }
          end)

        {:noreply, assign(socket, :rules, merged)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("propose", _params, socket) do
    actor = socket.assigns.current_user
    tenant = ActorContext.tenant(actor)

    case Proposal.propose(
           tenant,
           "AshEnterprise.Canonical.Person",
           socket.assigns.observed_schema,
           samples: socket.assigns.samples,
           actor: actor
         ) do
      {:ok, mapping} ->
        proposed =
          Map.new(mapping.field_rules, fn rule -> {rule["path"], rule["target"]} end)

        rules =
          Map.new(socket.assigns.rules, fn {field, rule} ->
            target = Map.get(proposed, field, "")

            {field,
             %{
               "target" => target,
               "op" => if(target == "", do: rule["op"], else: "identity"),
               "because" => rule["because"]
             }}
          end)

        {:noreply,
         socket
         |> assign(:rules, rules)
         |> put_flash(:info, "AI proposal loaded — review, then activate.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Proposal failed: #{message(reason)}")}
    end
  end

  def handle_event("validate-activate", _params, socket) do
    actor = socket.assigns.current_user
    tenant = ActorContext.tenant(actor)

    field_rules = build_field_rules(socket.assigns.rules)

    attrs = %{
      direction: :ingress,
      source: "manual_csv",
      stream: socket.assigns.slug,
      target_resource: "AshEnterprise.Canonical.Person",
      field_rules: field_rules,
      observed_schema: socket.assigns.observed_schema
    }

    # Every step runs as the person: drafting and validating need their
    # grants on Mapping exactly as activating does.
    with {:ok, draft} <-
           Mapping
           |> Ash.Changeset.for_create(:draft, attrs, tenant: tenant, actor: actor)
           |> Ash.create(),
         {:ok, validated} <-
           draft
           |> Ash.Changeset.for_update(:validate, %{}, tenant: tenant, actor: actor)
           |> Ash.update() do
      activate_validated(socket, validated, actor, tenant)
    else
      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Mapping refused: #{message(error)}")}
    end
  end

  # -- run step ---------------------------------------------------------------

  def handle_event("run-batch", _params, socket) do
    actor = socket.assigns.current_user
    tenant = ActorContext.tenant(actor)
    batch_input = %{mapping_id: socket.assigns.mapping_id, source_slug: socket.assigns.slug}

    # The batch opens as the person: their grant decides, and the rows land
    # only in the worker of a batch they were allowed to open.
    case BulkImport.start(socket.assigns.upload_id, batch_input, actor: actor, tenant: tenant) do
      {:ok, batch, job} ->
        Process.send_after(self(), :tick, 500)

        {:noreply,
         socket
         |> assign(:step, :running)
         |> assign(:batch, batch)
         |> assign(:job_id, job.id)
         |> assign(:tally, %{})
         |> assign(:done?, false)}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply,
         put_flash(socket, :error, "Import refused: you may not open an import batch here.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Import refused: #{upload_error(error)}")}
    end
  end

  # A file the wizard stored but never handed to a batch is removed when the
  # view goes away. Once a batch runs, its worker owns the file.
  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:step] in [:upload, :mapping] do
      BulkImport.discard(socket.assigns[:upload_id])
    end

    :ok
  end

  @impl true
  def handle_info(:tick, socket) do
    actor = socket.assigns.current_user
    tenant = ActorContext.tenant(actor)
    batch = socket.assigns.batch

    state =
      AshEnterprise.Repo.get!(Oban.Job, socket.assigns.job_id).state |> to_string()

    # One count per status, as the person: never the rows themselves.
    tally =
      for status <- @staged_statuses,
          count = staged_count(batch.id, status, tenant, actor),
          count > 0,
          into: %{},
          do: {status, count}

    batch = ImportBatch.by_id!(batch.id, tenant: tenant, actor: actor)
    socket = socket |> assign(:tally, tally) |> assign(:batch, batch)

    if state in ~w(completed failed cancelled discarded) do
      socket =
        case state do
          "failed" ->
            put_flash(socket, :error, "Import failed: #{batch.failure_reason}")

          _ ->
            socket
        end

      {:noreply, assign(socket, :done?, true)}
    else
      Process.send_after(self(), :tick, 500)
      {:noreply, socket}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp activate_validated(socket, %{status: :validated} = validated, actor, tenant) do
    case validated
         |> Ash.Changeset.for_update(:activate, %{activation_note: "ImportLive"},
           tenant: tenant,
           actor: actor
         )
         |> Ash.update() do
      {:ok, active} ->
        {:noreply,
         socket
         |> assign(:mapping_id, active.id)
         |> assign(:mappings, [active | socket.assigns.mappings])
         |> put_flash(:info, "Mapping activated — ready to run the import.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Activation refused: #{message(error)}")}
    end
  end

  defp activate_validated(socket, validated, _actor, _tenant) do
    findings = validated.validation_findings || %{"errors" => []}
    {:noreply, put_flash(socket, :error, "Validation refused: #{finding_text(findings)}")}
  end

  defp staged_count(batch_id, status, tenant, actor) do
    StagedRecord
    |> Ash.Query.filter(batch_id == ^batch_id and status == ^status)
    |> Ash.count!(tenant: tenant, actor: actor)
  end

  # The temp file LiveView wrote for this socket's own upload is copied into
  # the upload store before LiveView deletes it.
  defp store_csv(socket) do
    case consume_uploaded_entries(socket, :csv, fn meta, _entry ->
           {:ok, BulkImport.store_upload(meta.path)}
         end) do
      [{:ok, upload_id}] -> {:ok, upload_id}
      [{:error, reason}] -> {:error, reason}
      _ -> {:error, "no file was uploaded"}
    end
  end

  defp inspect_or_discard(upload_id) do
    case BulkImport.inspect_upload(upload_id) do
      {:ok, summary} ->
        {:ok, summary}

      error ->
        BulkImport.discard(upload_id)
        error
    end
  end

  defp upload_error({:over_cap, cap}),
    do: "the file has more than #{cap} rows; split it and import each part"

  defp upload_error(:unknown_upload),
    do: "the uploaded file is no longer available; upload it again"

  defp upload_error(reason) when is_binary(reason), do: reason
  defp upload_error(reason), do: message(reason)

  defp samples(headers, rows) do
    Map.new(headers, fn header ->
      {header, rows |> Enum.map(&Map.get(&1, header)) |> Enum.reject(&is_nil/1) |> Enum.take(5)}
    end)
  end

  # User rows become field rules, verbatim. Anything the person leaves
  # unmapped reaches the validator as an unaccounted target and the
  # activation is refused — total accounting is the person's contract to
  # meet, not the UI's to paper over with boilerplate.
  defp build_field_rules(rules) do
    rules
    |> Enum.reject(fn {_field, rule} -> rule["target"] == "" end)
    |> Enum.map(fn {field, rule} ->
      %{"path" => field, "target" => rule["target"], "op" => rule["op"], "args" => %{}}
      |> put_because(rule["because"])
    end)
  end

  defp put_because(rule, ""), do: rule
  defp put_because(rule, because), do: Map.put(rule, "because", because)

  defp finding_text(%{"errors" => errors}) do
    Enum.map_join(errors, ", ", fn e ->
      to_string(e["check"] || e[:check] || "invalid mapping")
    end)
  end

  defp finding_text(other), do: inspect(other)

  defp message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp message(%Ash.Error.Forbidden{}), do: "you are not permitted to do that"
  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(other), do: inspect(other)

  # -- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-5xl">
      <:toolbar>
        <.button navigate={~p"/app/mdm"} variant="ghost" size="sm">
          <.icon name="hero-hand-raised" class="size-4" /> Steward queue
        </.button>
      </:toolbar>

      <p class="text-sm text-foreground/70">
        Upload a customer CSV, map its columns onto the golden Person record, and run the
        import. Low-confidence matches await a steward at the <.link
          navigate={~p"/app/mdm"}
          class="underline underline-offset-2"
        >queue</.link>.
      </p>

      <.steps step={@step} />
      <%= case @step do %>
        <% :upload -> %>
          <.upload_step upload={@uploads.csv} />
        <% :mapping -> %>
          <.mapping_step {assigns} />
        <% :running -> %>
          <.run_step {assigns} />
      <% end %>
    </Layouts.app>
    """
  end

  defp steps(assigns) do
    ~H"""
    <ol id="import-steps" class="flex flex-wrap items-center gap-2 text-sm">
      <li>
        <.badge tone={step_tone(@step in [:upload, :mapping, :running])}>1 · Upload</.badge>
      </li>
      <li aria-hidden="true" class="text-foreground/50">→</li>
      <li>
        <.badge tone={step_tone(@step in [:mapping, :running])}>2 · Mapping</.badge>
      </li>
      <li aria-hidden="true" class="text-foreground/50">→</li>
      <li>
        <.badge tone={step_tone(@step == :running)}>3 · Run</.badge>
      </li>
    </ol>
    """
  end

  defp counter(batch, key), do: (batch.counts || %{})[key] || 0

  defp step_tone(true), do: "main"
  defp step_tone(false), do: nil

  # A hand-written field (a live file input, a select or text box inside a
  # table row) styled like `<.input>`'s control. Static string so Tailwind's
  # scanner sees it.
  defp control_class do
    "h-8 rounded-base border-2 border-border bg-secondary-background px-2 text-sm font-base text-foreground focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
  end

  defp upload_step(assigns) do
    ~H"""
    <.card>
      <.form
        id="import-upload-form"
        for={%{}}
        phx-change="validate"
        phx-submit="preview"
        class="space-y-4"
      >
        <.live_file_input
          upload={@upload}
          class="w-full max-w-lg rounded-base border-2 border-border bg-secondary-background text-sm file:me-3 file:h-10 file:cursor-pointer file:border-0 file:border-e-2 file:border-border file:bg-main file:px-4 file:text-main-foreground"
        />
        <.button
          id="preview-btn"
          type="submit"
          variant="primary"
          disabled={@upload.entries == []}
        >
          Preview
        </.button>
      </.form>
    </.card>
    """
  end

  defp mapping_step(assigns) do
    assigns = assign(assigns, :control_class, control_class())

    ~H"""
    <div class="space-y-4">
      <.card>
        <h2 class="font-heading">Parsed file</h2>
        <p class="text-sm text-foreground/70">
          {@row_count} rows · columns: {Enum.join(@headers, ", ")}
        </p>
      </.card>

      <.card>
        <h2 class="font-heading">Use an active ingress mapping</h2>
        <div class="grid gap-2">
          <label class="flex items-center gap-2 text-sm">
            <input
              type="radio"
              name="mapping-choice"
              class="accent-main"
              checked={is_nil(@mapping_id)}
            />
            <button
              type="button"
              phx-click="draft-new"
              class="cursor-pointer font-heading underline-offset-2 hover:underline"
            >
              Draft a new mapping
            </button>
          </label>
          <%= for mapping <- @mappings do %>
            <label class="flex items-center gap-2 rounded-base border-2 border-border p-2 text-sm hover:bg-main/10">
              <input
                type="radio"
                name="mapping-choice"
                class="accent-main"
                checked={@mapping_id == mapping.id}
                phx-click="select-mapping"
                phx-value-id={mapping.id}
              />
              <span>
                <span class="font-heading">{mapping.stream}</span>
                <span class="text-foreground/70">
                  — {Enum.map_join(mapping.field_rules, ", ", fn r ->
                    "#{r["path"]} → #{r["target"]}"
                  end)}
                </span>
              </span>
            </label>
          <% end %>
        </div>
      </.card>

      <.card :if={is_nil(@mapping_id)}>
        <h2 class="font-heading">Map the columns</h2>
        <.form id="mapping-editor" for={%{}} phx-change="rule-change">
          <div class="overflow-auto rounded-base border-2 border-border">
            <table class={table_class()}>
              <thead>
                <tr>
                  <th>CSV column</th><th>Golden field</th><th>Operation</th><th>
                    Because (unmapped)
                  </th>
                </tr>
              </thead>
              <tbody>
                <%= for field <- @headers do %>
                  <% rule = Map.get(@rules, field, %{}) %>
                  <tr id={"rule-#{field}"}>
                    <td class="font-heading">{field}</td>
                    <td>
                      <select class={[@control_class, "w-32"]} name={"rules[#{field}][target]"}>
                        <option value="" selected={rule["target"] == ""}>— unmapped —</option>
                        <option value="email" selected={rule["target"] == "email"}>email</option>
                        <option value="name" selected={rule["target"] == "name"}>name</option>
                      </select>
                    </td>
                    <td>
                      <select class={[@control_class, "w-40"]} name={"rules[#{field}][op]"}>
                        <%= for op <- AshMdm.Mapping.Evaluator.ops() do %>
                          <option value={op} selected={rule["op"] == op}>{op}</option>
                        <% end %>
                      </select>
                    </td>
                    <td>
                      <input
                        type="text"
                        class={[@control_class, "w-full"]}
                        name={"rules[#{field}][because]"}
                        value={rule["because"]}
                        placeholder="why this column is skipped"
                      />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.form>
        <div class="flex flex-wrap gap-2">
          <.button id="propose-btn" type="button" phx-click="propose" size="sm">
            <.icon name="hero-sparkles" class="size-4" /> AI proposal
          </.button>
          <.button
            id="validate-activate-btn"
            type="button"
            phx-click="validate-activate"
            variant="primary"
            size="sm"
          >
            Validate &amp; activate
          </.button>
        </div>
      </.card>
      <.card :if={@mapping_id}>
        <h2 class="font-heading">Run the import</h2>
        <.form
          id="run-form"
          for={%{}}
          phx-change="slug-change"
          class="flex flex-wrap items-center gap-2 text-sm"
        >
          <label for="run-slug">Source stream</label>
          <input
            id="run-slug"
            type="text"
            name="slug"
            value={@slug}
            class={[@control_class, "w-64"]}
          />
        </.form>
        <div>
          <.button
            id="run-batch-btn"
            type="button"
            phx-click="run-batch"
            variant="primary"
            size="sm"
          >
            Run import
          </.button>
        </div>
      </.card>
    </div>
    """
  end

  defp run_step(assigns) do
    ~H"""
    <div id="batch-progress" class="space-y-4">
      <%= if @done? do %>
        <.card accent="green">
          <h2 class="font-heading text-lg">Import finished</h2>
          <div class="overflow-auto rounded-base border-2 border-border">
            <table class={table_class()}>
              <tbody>
                <tr>
                  <th>Rows landed</th><td id="rows-landed">{counter(@batch, "landed")}</td>
                </tr>
                <tr>
                  <th>Rows refused</th><td id="rows-refused">{counter(@batch, "refused")}</td>
                </tr>
                <tr>
                  <th>Staged</th><td>
                    {Map.get(@tally, :staged, 0) + Map.get(@tally, :matched, 0) +
                      Map.get(@tally, :merged, 0) + Map.get(@tally, :rejected, 0) +
                      Map.get(@tally, :review, 0) + Map.get(@tally, :omitted, 0)}
                  </td>
                </tr>
                <tr :for={{status, count} <- Enum.sort(@tally)}>
                  <th class="capitalize">{status}</th><td>{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="flex flex-wrap gap-3 pt-2">
            <.button id="go-steward-link" navigate={~p"/app/mdm"} variant="primary" size="sm">
              Steward queue
            </.button>
            <.button
              id="go-batch-link"
              href={~p"/app/r/mdm_batches/#{@batch.id}"}
              variant="ghost"
              size="sm"
            >
              This batch
            </.button>
            <.button navigate={~p"/app/mdm/golden"} variant="ghost" size="sm">
              Golden records
            </.button>
            <.button navigate={~p"/app/processes"} variant="ghost" size="sm">
              Process model
            </.button>
          </div>
          <p :if={counter(@batch, "refused") > 0} class="text-sm">
            Rows that did not land are listed, with their row numbers and why, on <.link
              href={~p"/app/r/mdm_batches/#{@batch.id}"}
              class="underline"
            >this batch</.link>, and can be exported from there as CSV.
          </p>
          <p class="text-xs text-foreground/70">
            Each review-banded match runs the <code>mdm.steward_review</code> BPMN process —
            open it under Processes; banding itself is a DMN decision table.
          </p>
        </.card>
      <% else %>
        <.card>
          <h2 class="flex items-center gap-2 font-heading">
            Running <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
          </h2>
          <p class="text-sm text-foreground/70">
            Batch {String.slice(@batch.id, 0, 8)}… — staging, matching and banding the rows.
            <.link
              id="running-batch-link"
              href={~p"/app/r/mdm_batches/#{@batch.id}"}
              class="underline"
            >
              Open the batch
            </.link>
          </p>
        </.card>
      <% end %>
    </div>
    """
  end
end
