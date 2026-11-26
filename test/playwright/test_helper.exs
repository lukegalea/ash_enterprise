# The Playwright tier (`mix test.playwright`): the specs ported from Playwright Test, in dev,
# against the dev server that alias starts in this node as `mix phx.server` would (mix.exs).
# Its support is required here rather than compiled: dev compiles only lib/.
for file <- Path.wildcard(Path.join(__DIR__, "support/*.ex")), do: Code.require_file(file)

# Playwright Test's timeout here was 60 s, ExUnit's default. capture_log prints the server's
# log for a failed test only, as Playwright Test hid the webServer's output.
ExUnit.start(capture_log: true)
