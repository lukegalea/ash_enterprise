defmodule AshEnterprise.Integration.Outbound.EgressTest do
  @moduledoc """
  The outbound webhook egress guard: https on 443 only, every resolved address public, and
  the connection made to the address that was vetted. Pure: the resolver is a function the
  test supplies, so nothing here touches DNS or the network.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Integration.Outbound.Egress

  defp resolving(addresses), do: fn _host -> {:ok, addresses} end

  test "refuses http://" do
    assert {:error, "egress_scheme"} = Egress.check_url("http://hooks.example.test/in")

    assert {:error, "egress_scheme"} =
             Egress.vet("http://hooks.example.test/in", resolver: resolving([{1, 1, 1, 1}]))
  end

  test "refuses another port, user information and a malformed host" do
    assert {:error, "egress_port"} = Egress.check_url("https://hooks.example.test:8443/in")
    assert {:error, "egress_userinfo"} = Egress.check_url("https://user:pw@hooks.example.test/in")
    assert {:error, "egress_host"} = Egress.check_url("https://bad_host!/in")
    assert {:error, "egress_host"} = Egress.check_url(nil)
  end

  test "refuses a name resolving to 127.0.0.1, 10.0.0.0/8, 169.254.169.254, ::1, fc00::/7 or ::ffff:10.0.0.1" do
    for address <- [
          {127, 0, 0, 1},
          {10, 1, 2, 3},
          {169, 254, 169, 254},
          {172, 16, 0, 1},
          {192, 168, 1, 1},
          {100, 64, 0, 1},
          {0, 0, 0, 0},
          {224, 0, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          # ::ffff:10.0.0.1, the IPv4-mapped form, and ::ffff:1.1.1.1: mapped forms are refused, not unwrapped.
          {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
          {0, 0, 0, 0, 0, 0xFFFF, 0x0101, 0x0101},
          # 6to4 and NAT64 embed an IPv4 address too.
          {0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 1},
          {0x0064, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001}
        ] do
      assert {:error, "egress_private_address"} =
               Egress.vet("https://hooks.example.test/in", resolver: resolving([address])),
             "#{inspect(address)} was allowed"
    end
  end

  test "refuses a non-public IP literal at registration" do
    assert {:error, "egress_private_address"} = Egress.check_url("https://169.254.169.254/latest")
    assert {:error, "egress_private_address"} = Egress.check_url("https://[::1]/in")
    assert {:error, "egress_private_address"} = Egress.check_url("https://10.0.0.1/in")
  end

  test "refuses when any one of several resolved addresses is private" do
    assert {:error, "egress_private_address"} =
             Egress.vet("https://hooks.example.test/in",
               resolver: resolving([{1, 1, 1, 1}, {10, 0, 0, 1}])
             )

    assert {:error, "egress_private_address"} =
             Egress.vet("https://hooks.example.test/in",
               resolver: resolving([{1, 1, 1, 1}, {0, 0, 0, 0, 0, 0, 0, 1}])
             )
  end

  test "refuses an unresolvable host" do
    assert {:error, "egress_unresolvable"} =
             Egress.vet("https://nowhere.example.test/in",
               resolver: fn _ -> {:error, :nxdomain} end
             )

    assert {:error, "egress_unresolvable"} =
             Egress.vet("https://nowhere.example.test/in", resolver: resolving([]))
  end

  test "connects to the vetted address, not a re-resolved one" do
    calls = :counters.new(1, [])

    # Answers a public address once, then a private one: a rebinding attempt.
    resolver = fn _host ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1,
        do: {:ok, [{1, 1, 1, 1}]},
        else: {:ok, [{127, 0, 0, 1}]}
    end

    assert {:ok, vetted} = Egress.vet("https://hooks.example.test/in/abc?k=v", resolver: resolver)

    # The connection goes to the address, the name is kept for Host, SNI and verification,
    # and nothing is resolved again.
    assert vetted.address == {1, 1, 1, 1}
    assert vetted.base_url == "https://1.1.1.1:443"
    assert vetted.hostname == "hooks.example.test"
    assert vetted.path == "/in/abc?k=v"
    assert :counters.get(calls, 1) == 1
  end

  test "a public IPv6 address is vetted and bracketed" do
    assert {:ok, vetted} =
             Egress.vet("https://hooks.example.test",
               resolver: resolving([{0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}])
             )

    assert vetted.base_url == "https://[2606:4700:4700::1111]:443"
    assert vetted.path == "/"
  end
end
