{ pkgs, lib, config, ... }:

let
  # Pin the whole BEAM toolchain to one OTP release so Elixir, rebar3 and any
  # NIF-bearing dependency are all built against the same ERTS.
  #
  # OTP 27 + Elixir 1.18 is deliberately the same pairing that the official
  # ash-hq.org installer script pins, so we stay on the combination the Ash
  # ecosystem is actually tested against.
  beam = pkgs.beam.packages.erlang_27;

  # devenv's per-project state directory (`.devenv/state`). Everything mutable
  # and machine-local lives under here so the project is reproducible and
  # `rm -rf .devenv` is a genuine clean slate.
  stateDir = config.devenv.state;
in
{
  name = "ash_enterprise";

  # ---------------------------------------------------------------------------
  # Languages
  # ---------------------------------------------------------------------------
  languages.erlang = {
    enable = true;
    package = beam.erlang;
    # We drive this project from Claude Code; the Erlang LSP is a large build
    # with no consumer here. Flip to true if you attach an editor.
    lsp.enable = false;
  };

  languages.elixir = {
    enable = true;
    package = beam.elixir_1_18;
    lsp.enable = false; # see above; `expert` is the modern alternative to elixir-ls
  };

  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
  };

  # Used only by the offline CDM resolver in priv/cdm/tools. Python never enters
  # the build or CI path -- it produces committed intermediate JSON and stops.
  languages.python = {
    enable = true;
    venv.enable = true;
  };

  packages = with pkgs; [
    git
    inotify-tools # Phoenix live reload on Linux
    openssl
    jq
    curl
    graphviz # AshDiagram's Graphviz renderer (Mermaid renders client-side)
  ];

  # ---------------------------------------------------------------------------
  # Environment
  #
  # devenv's Elixir module sets `packages` and git-hooks only -- it does NOT
  # manage MIX_HOME/HEX_HOME/ERL_AFLAGS. Without the two below, mix and hex
  # write into ~/.mix and ~/.hex and silently leak state between projects.
  # ---------------------------------------------------------------------------
  env = {
    MIX_HOME = "${stateDir}/mix";
    HEX_HOME = "${stateDir}/hex";

    # MIX_ENV is deliberately NOT set. Exporting it pins the environment for
    # every mix invocation, so `mix test` runs in :dev -- config/test.exs is
    # never loaded, the Ecto SQL Sandbox pool is never configured, and the
    # suite dies with "cannot invoke sandbox operation with pool
    # DBConnection.ConnectionPool". Mix already defaults to :dev and each task
    # selects its own env.

    # Persistent IEx/erl shell history. The path argument must be a *quoted
    # Erlang string*, hence the nested quoting -- getting this wrong silently
    # disables history rather than erroring (elixir-lang/elixir#6475).
    ERL_AFLAGS = "-kernel shell_history enabled -kernel shell_history_path '\"${stateDir}/erlang-history\"'";

    # Postgres connection. services.postgres below listens on TCP because the
    # devenv default (`listen_addresses = ""`) is unix-socket-only, which
    # Postgrex cannot use.
    #
    # PGHOST and PGPORT are deliberately NOT set here -- the postgres module
    # defines them itself (as an int, in PGPORT's case) and redefining them
    # produces a conflicting-option-types evaluation error. psql picks them up
    # from the module; Ecto uses DATABASE_URL below.
    #
    # PGUSER/PGPASSWORD are likewise NOT set. initdb makes the *OS user* the
    # cluster superuser, and devenv's own setup script shells out to psql --
    # so exporting PGUSER=postgres makes devenv try to bootstrap the cluster as
    # a role that does not exist yet, and postgres never comes up. The
    # application connects as `postgres` via DATABASE_URL; devenv's internal
    # bootstrap connects as the OS user. Keep those two paths separate.
    PGDATABASE = "ash_enterprise_dev";

    # Credentials only. The host and port are NOT fixed here -- see below.
    DB_USER = "postgres";
    DB_PASSWORD = "postgres";

    LANG = "C.UTF-8";
  };

  enterShell = ''
    mkdir -p "$MIX_HOME" "$HEX_HOME" "${stateDir}/erlang-history"
    export PATH="$MIX_HOME/bin:$MIX_HOME/escripts:$HEX_HOME/bin:$PATH"

    # Resolve the port Postgres is ACTUALLY listening on.
    #
    # devenv allocates ports dynamically to avoid collisions with whatever is
    # already listening -- a system Postgres, a Docker container, another devenv
    # project. `services.postgres.port` is a request, not a guarantee: on a
    # machine with Docker holding 5432 and 5433, devenv silently settles on
    # 5434.
    #
    # The catch is that it rewrites postgresql.conf but leaves the exported
    # $PGPORT at the requested value, so the two disagree and every client
    # connects to the wrong place. postgresql.conf is the authoritative source,
    # so read it back when it exists (it will not on a cold checkout, before
    # the first `devenv up`).
    if [ -f "${stateDir}/postgres/postgresql.conf" ]; then
      _pgport="$(sed -n 's/^port = \([0-9]\+\).*/\1/p' "${stateDir}/postgres/postgresql.conf" | tail -n1)"
      [ -n "$_pgport" ] && export PGPORT="$_pgport"
      unset _pgport
    fi

    export DATABASE_URL="ecto://$DB_USER:$DB_PASSWORD@$PGHOST:$PGPORT/$PGDATABASE"
  '';

  # ---------------------------------------------------------------------------
  # PostgreSQL + pgvector
  # ---------------------------------------------------------------------------
  services.postgres = {
    enable = true;
    package = pkgs.postgresql_17;

    # `extensions` is a FUNCTION from the extension set to a list of packages;
    # devenv applies it as `package.withPackages extensions`. Do not pre-wrap
    # the package yourself or devenv throws a missing-withPackages error.
    extensions = extensions: [
      extensions.pgvector
    ];

    listen_addresses = "127.0.0.1";

    # A preference, not a promise: devenv shifts this if the port is taken.
    # Always read the actual value from $PGPORT (see enterShell).
    port = 5432;

    initdbArgs = [ "--locale=C" "--encoding=UTF8" ];

    # initdb makes the OS user the superuser, so the conventional `postgres`
    # role has to be created explicitly. NOTE: this runs only when the data
    # directory is first initialized -- if you change it, you must
    # `rm -rf .devenv/state/postgres` for the change to take effect.
    initialScript = ''
      CREATE ROLE postgres SUPERUSER LOGIN PASSWORD 'postgres';
    '';

    initialDatabases = [
      { name = "ash_enterprise_dev"; }
      { name = "ash_enterprise_test"; }
    ];

    settings = {
      shared_buffers = "256MB";
      max_connections = 200;
      log_connections = false;
      # Flip to "all" when you want to watch the SQL that Ash generates.
      log_statement = "none";
      # This database is disposable dev/test state, so trade durability for the
      # test-suite speed that matters far more here.
      fsync = false;
      synchronous_commit = false;
      full_page_writes = false;
    };
  };

  # ---------------------------------------------------------------------------
  # Processes (devenv up)
  #
  # `devenv up` runs INFRASTRUCTURE ONLY -- currently just Postgres. The Phoenix
  # server is deliberately not a managed process.
  #
  # Two reasons. First, `mix phx.server` takes the _build lock, so a supervised
  # copy silently blocks every `mix compile`, `mix test` and `mix ash.codegen`
  # you run in another terminal -- and because process-compose restarts it, it
  # takes the lock straight back. Second, you almost always want the app inside
  # IEx anyway, for `Ash.read/2` at a prompt and for Tidewave's project_eval.
  #
  # So: `devenv up -d` for infra, then `iex-server` for the app.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Scripts
  # ---------------------------------------------------------------------------
  scripts.setup = {
    description = "Install deps and create + migrate the database";
    exec = ''
      set -euo pipefail
      mix local.hex --force --if-missing
      mix local.rebar --force --if-missing
      mix deps.get
      mix ash.setup
      if [ -d assets ]; then (cd assets && npm install); fi
    '';
  };

  scripts.reset-db = {
    description = "Drop, recreate and re-migrate the dev database";
    exec = "set -euo pipefail; mix ash.reset";
  };

  scripts.codegen = {
    description = "Check that Ash-generated migrations are in sync with the resources";
    exec = ''
      set -euo pipefail
      mix ash.codegen --check || {
        echo ""
        echo "Ash codegen is out of date. Run: mix ash.codegen <descriptive_name>"
        exit 1
      }
    '';
  };

  scripts.check = {
    description = "Run the full local quality gate (what CI runs)";
    exec = ''
      set -euo pipefail
      mix format --check-formatted
      mix compile --warnings-as-errors
      mix credo --strict
      mix ash.codegen --check
      mix test
    '';
  };

  scripts.iex-server = {
    description = "Start Phoenix inside IEx";
    exec = "iex -S mix phx.server";
  };

  # ---------------------------------------------------------------------------
  # Git hooks
  # ---------------------------------------------------------------------------
  # pre-commit runs hooks in a minimal environment that does NOT inherit the
  # `env` block above. devenv's stock mix-format hook therefore cannot find the
  # project-local HEX_HOME, and fails with a confusing
  # "Could not find an SCM for dependency :ash_credo" -- mix is really telling
  # you it has no Hex at all. So point the hook back at our state directory.
  git-hooks.hooks.mix-format = {
    enable = true;
    files = "\\.(ex|exs|heex)$";
    pass_filenames = true;
    entry = toString (pkgs.writeShellScript "mix-format-hook" ''
      export MIX_HOME="${stateDir}/mix"
      export HEX_HOME="${stateDir}/hex"
      exec ${config.languages.elixir.package}/bin/mix format "$@"
    '');
  };

  dotenv.enable = true; # .env carries OPENAI_API_KEY / ANTHROPIC_API_KEY etc.
}
