defmodule AshEnterprise.Integration.Outbound.Egress do
  @moduledoc """
  The egress guard for outbound webhooks: a URL a tenant registered is reached only at a
  public address, vetted once per send, and the connection goes to the address that was
  vetted.

  `check_url/1` is the static half, run when an endpoint is registered: `https` only, port
  443 only, no user information, and a host that is not a non-public IP literal.

  `vet/2` is the half run on every send:

    1. the static checks again;
    2. resolve every A and AAAA record of the host;
    3. refuse if **any** resolved address is not public: loopback, the private ranges
       (RFC 1918, `100.64.0.0/10`), link-local and the cloud metadata address
       (`169.254.0.0/16`), `0.0.0.0/8`, the documentation and benchmarking ranges,
       multicast and reserved space; for IPv6 the unspecified and loopback addresses,
       `fc00::/7`, `fe80::/10`, multicast, the documentation prefix, and every form that
       embeds an IPv4 address (IPv4-mapped, IPv4-compatible, NAT64, 6to4, Teredo), which
       are refused rather than unwrapped;
    4. return the first vetted address with the name it was vetted for.

  The caller connects to that address and keeps the name for the `Host` header, SNI and
  certificate verification (`connect_options: [hostname: name]`), so a DNS answer that
  changes between the check and the connection (rebinding) cannot change the target.
  Redirects are never followed (the transport sets `redirect: false`).

  Lives in the host for its first use (ADR 0070); it moves to `ash_operations` at the
  second.

  Refusals are short codes, never the address: `"egress_scheme"`, `"egress_port"`,
  `"egress_userinfo"`, `"egress_host"`, `"egress_private_address"`, `"egress_unresolvable"`.
  The resolver is `:inet.getaddrs/2` unless `resolver:` (a 1-arity function from a
  charlist host to `{:ok, [address]}` or `{:error, reason}`) is given or configured under
  `config :ash_enterprise, #{inspect(__MODULE__)}, resolver: ...` (tests).
  """

  import Bitwise

  @type vetted :: %{
          address: :inet.ip_address(),
          hostname: String.t(),
          base_url: String.t(),
          path: String.t()
        }

  @type code :: String.t()

  @doc "The static checks on a URL a tenant registers."
  @spec check_url(term()) :: {:ok, URI.t()} | {:error, code()}
  def check_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> check_uri(uri)
      {:error, _} -> {:error, "egress_host"}
    end
  end

  def check_url(_url), do: {:error, "egress_host"}

  defp check_uri(%URI{scheme: scheme}) when scheme != "https", do: {:error, "egress_scheme"}
  defp check_uri(%URI{userinfo: info}) when not is_nil(info), do: {:error, "egress_userinfo"}
  defp check_uri(%URI{port: port}) when port != 443, do: {:error, "egress_port"}
  defp check_uri(%URI{host: host}) when host in [nil, ""], do: {:error, "egress_host"}

  defp check_uri(%URI{host: host} = uri) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} ->
        if public?(address), do: {:ok, uri}, else: {:error, "egress_private_address"}

      {:error, _} ->
        if valid_name?(host), do: {:ok, uri}, else: {:error, "egress_host"}
    end
  end

  defp valid_name?(host) do
    byte_size(host) <= 253 and
      host =~
        ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*\.?$/
  end

  @doc "Vet a URL for one send: the static checks, then every resolved address."
  @spec vet(String.t(), keyword()) :: {:ok, vetted()} | {:error, code()}
  def vet(url, opts \\ []) do
    with {:ok, uri} <- check_url(url),
         {:ok, addresses} <- resolve(uri.host, resolver(opts)),
         :ok <- all_public(addresses) do
      address = hd(addresses)

      {:ok,
       %{
         address: address,
         hostname: uri.host,
         base_url: "https://#{format(address)}:443",
         path: path(uri)
       }}
    end
  end

  defp resolver(opts) do
    Keyword.get_lazy(opts, :resolver, fn ->
      Keyword.get(Application.get_env(:ash_enterprise, __MODULE__, []), :resolver, &getaddrs/1)
    end)
  end

  defp getaddrs(host) do
    v4 = :inet.getaddrs(host, :inet)
    v6 = :inet.getaddrs(host, :inet6)

    case {v4, v6} do
      {{:ok, a}, {:ok, b}} -> {:ok, a ++ b}
      {{:ok, a}, _} -> {:ok, a}
      {_, {:ok, b}} -> {:ok, b}
      {error, _} -> error
    end
  end

  defp resolve(host, resolver) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _} ->
        case resolver.(String.to_charlist(host)) do
          {:ok, [_ | _] = addresses} -> {:ok, addresses}
          _ -> {:error, "egress_unresolvable"}
        end
    end
  end

  defp all_public(addresses) do
    if Enum.all?(addresses, &public?/1), do: :ok, else: {:error, "egress_private_address"}
  end

  defp path(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query in [nil, ""], do: path, else: path <> "?" <> query
  end

  defp format({_, _, _, _} = address), do: address |> :inet.ntoa() |> to_string()
  defp format(address), do: "[" <> (address |> :inet.ntoa() |> to_string()) <> "]"

  @doc "Whether an address is public: reachable on the internet and not special-purpose."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({a, b, c, d} = address)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    int = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

    not Enum.any?(ipv4_refused(), fn {net, bits} -> in_v4?(int, net, bits) end) and
      address != {255, 255, 255, 255}
  end

  def public?({_, _, _, _, _, _, _, _} = address) do
    int = Enum.reduce(Tuple.to_list(address), 0, fn part, acc -> acc <<< 16 ||| part end)

    # Global unicast only (2000::/3), less the special prefixes inside it.
    in_v6?(int, {0x2000, 0, 0, 0, 0, 0, 0, 0}, 3) and
      not Enum.any?(ipv6_refused(), fn {net, bits} -> in_v6?(int, net, bits) end)
  end

  def public?(_address), do: false

  defp ipv4_refused do
    [
      {{0, 0, 0, 0}, 8},
      {{10, 0, 0, 0}, 8},
      {{100, 64, 0, 0}, 10},
      {{127, 0, 0, 0}, 8},
      {{169, 254, 0, 0}, 16},
      {{172, 16, 0, 0}, 12},
      {{192, 0, 0, 0}, 24},
      {{192, 0, 2, 0}, 24},
      {{192, 88, 99, 0}, 24},
      {{192, 168, 0, 0}, 16},
      {{198, 18, 0, 0}, 15},
      {{198, 51, 100, 0}, 24},
      {{203, 0, 113, 0}, 24},
      {{224, 0, 0, 0}, 4},
      {{240, 0, 0, 0}, 4}
    ]
  end

  defp ipv6_refused do
    [
      # Teredo and the IETF protocol assignments (2001::/23 holds both).
      {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
      # Documentation.
      {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32},
      # 6to4, which embeds an IPv4 address.
      {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
      # ORCHIDv2 and benchmarking.
      {{0x2001, 0x0020, 0, 0, 0, 0, 0, 0}, 28},
      {{0x2001, 0x0002, 0, 0, 0, 0, 0, 0}, 48}
    ]
  end

  defp in_v4?(int, {a, b, c, d}, bits) do
    net = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
    mask = bnot((1 <<< (32 - bits)) - 1) &&& 0xFFFFFFFF
    (int &&& mask) == (net &&& mask)
  end

  defp in_v6?(int, net, bits) do
    net = Enum.reduce(Tuple.to_list(net), 0, fn part, acc -> acc <<< 16 ||| part end)
    shift = 128 - bits
    int >>> shift == net >>> shift
  end
end
