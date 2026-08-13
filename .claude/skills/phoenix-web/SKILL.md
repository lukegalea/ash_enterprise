---
name: phoenix-web
description: "Use when working on LiveViews, controllers, components, or the router."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

### phoenix

- [ecto](references/phoenix/ecto.md)
- [elixir](references/phoenix/elixir.md)
- [html](references/phoenix/html.md)
- [liveview](references/phoenix/liveview.md)
- [phoenix](references/phoenix/phoenix.md)

### ash_phoenix

- [ash_phoenix](references/ash_phoenix/ash_phoenix.md)
- [best_practices](references/ash_phoenix/best_practices.md)
- [debugging_form_submissions](references/ash_phoenix/debugging_form_submissions.md)
- [error_handling](references/ash_phoenix/error_handling.md)
- [form_integration](references/ash_phoenix/form_integration.md)
- [nested_forms](references/ash_phoenix/nested_forms.md)
- [union_forms](references/ash_phoenix/union_forms.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p phoenix -p ash_phoenix
```

## Available Mix Tasks

- `mix compile.phoenix`
- `mix phx` - Prints Phoenix help information
- `mix phx.digest` - Digests and compresses static files
- `mix phx.digest.clean` - Removes old versions of static assets.
- `mix phx.gen` - Lists all available Phoenix generators
- `mix phx.gen.auth` - Generates authentication logic for a resource
- `mix phx.gen.auth.hashing_library`
- `mix phx.gen.auth.injector`
- `mix phx.gen.auth.migration`
- `mix phx.gen.cert` - Generates a self-signed certificate for HTTPS testing
- `mix phx.gen.channel` - Generates a Phoenix channel
- `mix phx.gen.context` - Generates a context with functions around an Ecto schema
- `mix phx.gen.embedded` - Generates an embedded Ecto schema file
- `mix phx.gen.html` - Generates context and controller for an HTML resource
- `mix phx.gen.json` - Generates context and controller for a JSON resource
- `mix phx.gen.live` - Generates LiveView, templates, and context for a resource
- `mix phx.gen.notifier` - Generates a notifier that delivers emails by default
- `mix phx.gen.presence` - Generates a Presence tracker
- `mix phx.gen.release` - Generates release files and optional Dockerfile for release-based deployments
- `mix phx.gen.schema` - Generates an Ecto schema and migration file
- `mix phx.gen.secret` - Generates a secret
- `mix phx.gen.socket` - Generates a Phoenix socket handler
- `mix phx.routes` - Prints all routes
- `mix phx.server` - Starts applications and their servers
- `mix ash_phoenix.gen.html` - Generates a controller and HTML views for an existing Ash resource.
- `mix ash_phoenix.gen.live` - Generates liveviews for a given domain and resource.
- `mix ash_phoenix.install` - Installs AshPhoenix into a project. Should be called with `mix igniter.install ash_phoenix`
<!-- usage-rules-skill-end -->
