defmodule AshEnterprise.Finance.Tiller.Rows do
  @moduledoc """
  A Tiller sheet's two tabs, read: the `values` of a Sheets
  `values.batchGet` range (rows of cells, the first row the headers) turned
  into observations, one per row, each with a stable key. Pure: no reads, no
  clock, no keys of its own (the keyed row key comes in as a function).

  Read with `valueRenderOption=UNFORMATTED_VALUE` and
  `dateTimeRenderOption=SERIAL_NUMBER`: amounts arrive as numbers (decoded as
  `Decimal` at the edge, never a float) and dates as day serials, both
  unambiguous, where formatted values depend on the sheet's locale.

  ## Columns are found by header

  Tiller's users reorder and add columns, so a column is its header, never
  its position. A tab without the headers it needs is refused whole
  (`{:error, {:unexpected_layout, missing}}`): reading a reshuffled sheet as
  if it were the old one would invent changes, and removals.

  **Transactions** need `Date` and `Amount`, and `Account ID` or `Account`.
  Read as well, when present: `Description`, `Full Description`, `Category`,
  `Account #`, `Institution`, `Transaction ID`, `Date Added`,
  `Categorized By`, `Source`, `Merchant Name`, `Category Hint`,
  `Categorized Date`, `Note`, `Tags`. (`Month` and `Week` are derived from
  `Date` and kept only in the raw row.)

  **Balance History** needs `Date` and `Balance`, and `Account ID` or
  `Account`. Also read: `Time (UTC)` (or `Time`), `Account #`,
  `Institution`. `Type` and `Class` are unreliable (Tiller's forum) and kept
  only in the raw row.

  ## Keys

    * A transaction with a `Transaction ID` is keyed on it: `t:<id>`.
    * A manual row has none. It is keyed on a keyed digest of its account,
      date, amount and full description, and its occurrence among rows
      identical in those (the second identical coffee on the same card that
      day is `…#2`): `m:<digest>`.
    * A balance row is keyed on its account, date, time and occurrence:
      `b:<digest>`.

  A repeated `Transaction ID` takes an occurrence suffix too, so two rows
  never share a key.

  ## Rows that cannot be read

  A row whose date or amount cannot be read is not an observation; it is
  counted under `skipped` by reason, never quoted. A row with no cell at all
  is a blank row and is ignored.
  """

  @serial_epoch ~D[1899-12-30]

  @transaction_fields %{
    "Description" => "description",
    "Full Description" => "full_description",
    "Category" => "category",
    "Account" => "account",
    "Account #" => "account_mask",
    "Institution" => "institution",
    "Account ID" => "account_id",
    "Transaction ID" => "transaction_id",
    "Categorized By" => "categorized_by",
    "Source" => "feed",
    "Merchant Name" => "merchant_name",
    "Category Hint" => "category_hint",
    "Note" => "note",
    "Tags" => "tags"
  }

  @balance_fields %{
    "Account" => "account",
    "Account #" => "account_mask",
    "Institution" => "institution",
    "Account ID" => "account_id"
  }

  @typedoc "A raw row: header → cell, blank cells left out."
  @type raw_row :: %{String.t() => term()}

  @typedoc """
  One observation: its key, the raw row as read (what lands, sealed), and the
  account its currency is declared for.
  """
  @type observation :: %{key: String.t(), account_ref: String.t(), row: raw_row()}

  @type parsed :: %{observations: [observation()], skipped: %{atom() => pos_integer()}}

  @doc """
  A tab's `values` as the source emitted them, read by header: the headers,
  and each non-blank row as header → cell. What the adapter hands the step.
  """
  @spec table([[term()]]) :: {:ok, [String.t() | nil], [raw_row()]}
  def table([header_row | rows]) when is_list(header_row) do
    headers = Enum.map(header_row, &header/1)

    {:ok, headers,
     rows
     |> Enum.map(&to_row(headers, &1))
     |> Enum.reject(&(map_size(&1) == 0))}
  end

  def table(_values), do: {:ok, [], []}

  @doc """
  Key the Transactions tab's rows. `row_key` turns a list of identifying
  parts into a keyed digest (`AshEnterprise.Finance.Sealing.row_key/2`).
  """
  @spec transactions([String.t() | nil], [raw_row()], ([String.t()] -> String.t())) ::
          {:ok, parsed()} | {:error, {:unexpected_layout, [String.t()]}}
  def transactions(headers, rows, row_key) do
    with :ok <- layout(headers, ["Date", "Amount"]) do
      observe(rows, &transaction_identity/1, row_key, "t")
    end
  end

  @doc "Key the Balance History tab's rows (see `transactions/3`)."
  @spec balances([String.t() | nil], [raw_row()], ([String.t()] -> String.t())) ::
          {:ok, parsed()} | {:error, {:unexpected_layout, [String.t()]}}
  def balances(headers, rows, row_key) do
    with :ok <- layout(headers, ["Date", "Balance"]) do
      observe(rows, &balance_identity/1, row_key, "b")
    end
  end

  @doc """
  A transaction row, normalized: what the mappings read. `currency` is the
  account's declared currency. `{:error, reason}` when the date or amount
  cannot be read.
  """
  @spec normalize_transaction(raw_row(), String.t()) :: {:ok, map()} | {:error, atom()}
  def normalize_transaction(row, currency) do
    with {:ok, date} <- date(row["Date"]),
         {:ok, amount} <- decimal(row["Amount"]) do
      fields =
        Map.new(@transaction_fields, fn {header, field} -> {field, text(row[header])} end)

      {:ok,
       Map.merge(fields, %{
         "occurred_at" => midnight(date),
         "posted_on" => date,
         "amount" => money(amount, currency),
         "currency" => currency,
         "date_added" => optional_date(row["Date Added"]),
         "categorized_on" => optional_date(row["Categorized Date"])
       })}
    end
  end

  @doc "A balance row, normalized (see `normalize_transaction/2`)."
  @spec normalize_balance(raw_row(), String.t()) :: {:ok, map()} | {:error, atom()}
  def normalize_balance(row, currency) do
    with {:ok, date} <- date(row["Date"]),
         {:ok, balance} <- decimal(row["Balance"]) do
      fields = Map.new(@balance_fields, fn {header, field} -> {field, text(row[header])} end)
      time = time(row["Time (UTC)"] || row["Time"])

      {:ok,
       Map.merge(fields, %{
         "occurred_at" => DateTime.new!(date, time, "Etc/UTC") |> usec(),
         "observed_on" => date,
         "balance" => money(balance, currency),
         "currency" => currency
       })}
    end
  end

  @doc "The account a row's currency is declared for: its `Account ID`, else its `Account`."
  @spec account_ref(raw_row()) :: String.t() | nil
  def account_ref(row), do: text(row["Account ID"]) || text(row["Account"])

  # --- the tab --------------------------------------------------------------------

  defp layout(headers, required) do
    missing =
      Enum.reject(required, &(&1 in headers)) ++
        if Enum.any?(["Account ID", "Account"], &(&1 in headers)), do: [], else: ["Account ID"]

    if missing == [], do: :ok, else: {:error, {:unexpected_layout, missing}}
  end

  defp header(cell) when is_binary(cell), do: String.trim(cell)
  defp header(_cell), do: nil

  # Header → cell, the first column of a repeated header winning, blank and
  # header-less cells left out.
  defp to_row(headers, cells) when is_list(cells) do
    headers
    |> Enum.zip(cells)
    |> Enum.reduce(%{}, fn
      {nil, _cell}, acc -> acc
      {_header, cell}, acc when cell in [nil, ""] -> acc
      {header, cell}, acc -> Map.put_new(acc, header, trim(cell))
    end)
  end

  defp to_row(_headers, _cells), do: %{}

  defp trim(cell) when is_binary(cell), do: String.trim(cell)
  defp trim(cell), do: cell

  # --- keys -----------------------------------------------------------------------

  defp observe(rows, identity, row_key, prefix) do
    {observations, skipped, _seen} =
      Enum.reduce(rows, {[], %{}, %{}}, fn row, {acc, skipped, seen} ->
        case identity.(row) do
          {:ok, kind, parts} ->
            occurrence = Map.get(seen, {kind, parts}, 0) + 1
            key = key(kind, parts, occurrence, row_key, prefix)

            {[%{key: key, account_ref: account_ref(row), row: row} | acc], skipped,
             Map.put(seen, {kind, parts}, occurrence)}

          {:error, reason} ->
            {acc, Map.update(skipped, reason, 1, &(&1 + 1)), seen}
        end
      end)

    {:ok, %{observations: Enum.reverse(observations), skipped: skipped}}
  end

  defp key(:id, [id], 1, _row_key, _prefix), do: "t:" <> id
  defp key(:id, [id], n, _row_key, _prefix), do: "t:#{id}##{n}"

  defp key(:content, parts, n, row_key, "t"),
    do: "m:" <> row_key.(parts ++ [Integer.to_string(n)])

  defp key(:content, parts, n, row_key, prefix),
    do: prefix <> ":" <> row_key.(parts ++ [Integer.to_string(n)])

  defp transaction_identity(row) do
    with {:ok, date} <- date(row["Date"]),
         {:ok, amount} <- decimal(row["Amount"]) do
      case text(row["Transaction ID"]) do
        nil ->
          {:ok, :content,
           [
             account_ref(row) || "",
             Date.to_iso8601(date),
             Decimal.to_string(Decimal.normalize(amount), :normal),
             text(row["Full Description"]) || text(row["Description"]) || ""
           ]}

        id ->
          {:ok, :id, [id]}
      end
    end
  end

  defp balance_identity(row) do
    with {:ok, date} <- date(row["Date"]),
         {:ok, _balance} <- decimal(row["Balance"]) do
      {:ok, :content,
       [
         account_ref(row) || "",
         Date.to_iso8601(date),
         Time.to_iso8601(time(row["Time (UTC)"] || row["Time"]))
       ]}
    end
  end

  # --- cells ----------------------------------------------------------------------

  defp date(serial) when is_integer(serial), do: {:ok, Date.add(@serial_epoch, serial)}

  defp date(%Decimal{} = serial) do
    serial |> Decimal.round(0, :down) |> Decimal.to_integer() |> date()
  end

  defp date(text) when is_binary(text) do
    case Date.from_iso8601(String.slice(text, 0, 10)) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :unreadable_date}
    end
  end

  defp date(_cell), do: {:error, :unreadable_date}

  defp optional_date(nil), do: nil

  defp optional_date(cell) do
    case date(cell) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  # A day serial's fraction (Tiller's `Time (UTC)`), or "HH:MM[:SS]".
  defp time(%Decimal{} = serial) do
    fraction = Decimal.sub(serial, Decimal.round(serial, 0, :down))

    seconds =
      fraction
      |> Decimal.mult(86_400)
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()
      |> min(86_399)

    Time.add(~T[00:00:00], seconds)
  end

  defp time(text) when is_binary(text) do
    padded = if String.length(text) == 5, do: text <> ":00", else: text

    case Time.from_iso8601(padded) do
      {:ok, time} -> Time.truncate(time, :second)
      {:error, _} -> ~T[00:00:00]
    end
  end

  defp time(_cell), do: ~T[00:00:00]

  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(%Decimal{} = value), do: {:ok, value}

  defp decimal(text) when is_binary(text) do
    case Decimal.parse(text) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, :unreadable_amount}
    end
  end

  defp decimal(_cell), do: {:error, :unreadable_amount}

  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp text(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(value) when is_boolean(value), do: to_string(value)
  defp text(_value), do: nil

  defp money(amount, currency), do: %{"amount" => amount, "currency" => currency}

  # The date boundary convention (ADR 0049): a date is its T00:00:00Z.
  defp midnight(date), do: date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> usec()

  defp usec(%DateTime{} = datetime), do: %{datetime | microsecond: {0, 6}}
end
