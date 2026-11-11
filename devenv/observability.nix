# SigNoz and GlitchTip for a development environment, without Docker.
#
# Import through devenv.yaml:
#
#   inputs:
#     ash_enterprise:
#       url: github:lukegalea/ash_enterprise/<sha>
#       flake: false
#   imports:
#     - ash_enterprise/devenv/observability.nix
#
# Then, from the devenv shell: `observability up|down|status|urls`. Nothing starts
# with `devenv up`. See devenv/observability/README.md.
{ pkgs, lib, config, ... }:

let
  cfg = config.observability;

  arch =
    {
      x86_64-linux = "amd64";
      aarch64-linux = "arm64";
    }.${pkgs.stdenv.hostPlatform.system} or null;
  supported = arch != null;

  # Every download is an exact release asset with its hash, from each project's
  # published checksums.
  pins = {
    signoz = {
      version = "0.149.0";
      url = a: "https://github.com/SigNoz/signoz/releases/download/v0.149.0/signoz-community_linux_${a}.tar.gz";
      hash = {
        amd64 = "88283b8971974fe7720996b2fec99668d1bf0102694b6ee7b83db4d3c8784287";
        arm64 = "52c1776ac641cbb55990cee0a15e3c01f4d2437e5e6271ac51a73344f7bd5785";
      };
    };
    collector = {
      version = "0.144.15";
      url = a: "https://github.com/SigNoz/signoz-otel-collector/releases/download/v0.144.15/signoz-otel-collector_linux_${a}.tar.gz";
      hash = {
        amd64 = "232f931ef997083a7b8062e12e44b5bfaaf984b3ce0504c724d8d6c990dca025";
        arm64 = "06fc58f7e82269f3405e02fd7a18834e9f25de3592b013125a6dbdf834564db0";
      };
    };
    migrator = {
      version = "0.144.15";
      url = a: "https://github.com/SigNoz/signoz-otel-collector/releases/download/v0.144.15/signoz-schema-migrator_linux_${a}.tar.gz";
      hash = {
        amd64 = "6e617a57cd21fa8681c16da2fb2e8755616e2688ed5b1d227f306444c77f1586";
        arm64 = "b63a0645afc607672ad7f5e59f0d3201aebed8006dc39ab3a41a4f542aad7cf8";
      };
    };
    histogramQuantile = {
      version = "0.0.1";
      url = a: "https://github.com/SigNoz/signoz/releases/download/histogram-quantile%2Fv0.0.1/histogram-quantile_linux_${a}.tar.gz";
      hash = {
        amd64 = "33997073eb6d82b7be4f27f9fc8ec9e28a395e0f20674d5d54bb2fa28a75488d";
        arm64 = "e5605ebffa82a450ebbcdf6cf19dad546e1e40d52dbf3e03cfd2d2d5b7394211";
      };
    };
  };

  # The tarballs are glibc binaries with an FHS interpreter. Patching them works on
  # NixOS and in containers alike, and costs nothing where the FHS path exists.
  release = name: pin:
    pkgs.stdenv.mkDerivation {
      pname = "observability-${name}";
      inherit (pin) version;
      src = pkgs.fetchurl {
        url = pin.url arch;
        sha256 = pin.hash.${arch};
      };
      sourceRoot = ".";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      dontConfigure = true;
      dontBuild = true;
      dontStrip = true;
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        for entry in *; do
          if [ -d "$entry" ] && [ -d "$entry/bin" ]; then
            cp -r "$entry"/* "$out"/
          else
            cp -r "$entry" "$out"/
          fi
        done
        runHook postInstall
      '';
    };

  signoz = release "signoz" pins.signoz;
  collector = release "collector" pins.collector;
  migrator = release "migrator" pins.migrator;
  histogramQuantile = release "histogram-quantile" pins.histogramQuantile;
  clickhouse = pkgs.clickhouse-lts;
  glitchtip = pkgs.glitchtip;
  glitchtipPython = glitchtip.python;
  postgres =
    if config.services.postgres.enable then config.services.postgres.package else pkgs.postgresql;

  glitchtipPythonPath = pkgs.runCommand "glitchtip-pythonpath.sh" { } ''
    grep -E '^(PYTHONPATH=|export PYTHONPATH)' ${glitchtip}/bin/glitchtip-manage > "$out"
  '';

  configDir = builtins.path {
    path = ./observability;
    name = "observability-config";
  };

  # The one place the span-metrics choice lives. Off: no processor, no RED metric
  # series, and SigNoz's Services page reads the trace tables. On: the processor
  # writes signoz_calls_total/signoz_latency and SigNoz reads those.
  spanMetricsProcessor = ''
      signozspanmetrics/delta:
        metrics_exporter: signozclickhousemetrics
        latency_histogram_buckets: [100us, 1ms, 2ms, 6ms, 10ms, 50ms, 100ms, 250ms, 500ms, 1000ms, 1400ms, 2000ms, 5s, 10s, 20s, 40s, 60s]
        dimensions_cache_size: 5000
        aggregation_temporality: AGGREGATION_TEMPORALITY_DELTA
        enable_exp_histogram: true
        dimensions:
          - name: service.namespace
            default: default
          - name: deployment.environment
            default: default
          - name: signoz.collector.id
  '';

  collectorTemplate = pkgs.writeText "collector.yaml" (
    builtins.replaceStrings
      [ "@SPANMETRICS_PROCESSOR@\n" "@SPANMETRICS_REF@" ]
      [ (lib.optionalString cfg.spanMetrics spanMetricsProcessor) (lib.optionalString cfg.spanMetrics "signozspanmetrics/delta, ") ]
      (builtins.readFile ./observability/collector.yaml)
  );

  appEnvLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") cfg.appEnv
  );

  impl = pkgs.writeShellApplication {
    name = "observability-impl";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      curl
      findutils
      gawk
      gnugrep
      gnused
      jq
      postgres
      procps
      util-linux
    ];
    runtimeEnv = {
      OBS_SIGNOZ = "${signoz}";
      OBS_COLLECTOR = "${collector}";
      OBS_MIGRATOR = "${migrator}";
      OBS_HISTOGRAM_QUANTILE = "${histogramQuantile}";
      OBS_CLICKHOUSE = "${clickhouse}";
      OBS_GLITCHTIP = "${glitchtip}";
      OBS_GLITCHTIP_PYTHON = "${glitchtipPython}";
      OBS_GLITCHTIP_PYTHONPATH = "${glitchtipPythonPath}";
      OBS_GRANIAN = "${glitchtipPython.pkgs.granian}";
      OBS_CONFIG_DIR = "${configDir}";
      OBS_CONFIG_COLLECTOR = "${collectorTemplate}";
      OBS_RETENTION_DAYS = toString cfg.retentionDays;
      OBS_ROOT_EMAIL = cfg.rootEmail;
      OBS_GLITCHTIP_SLUG = cfg.organization;
      OBS_SPAN_METRICS = lib.boolToString cfg.spanMetrics;
      OBS_APP_ENV = appEnvLines;
      OBS_BUDGET_CLICKHOUSE = toString cfg.budgetMb.clickhouse;
      OBS_BUDGET_COLLECTOR = toString cfg.budgetMb.collector;
      OBS_BUDGET_SIGNOZ = toString cfg.budgetMb.signoz;
      OBS_BUDGET_GLITCHTIP = toString cfg.budgetMb.glitchtip;
      OBS_BUDGET_TOTAL = toString cfg.budgetMb.total;
      OBS_MEMMAX_CLICKHOUSE = toString cfg.memoryMaxMb.clickhouse;
      OBS_MEMMAX_COLLECTOR = toString cfg.memoryMaxMb.collector;
      OBS_MEMMAX_SIGNOZ = toString cfg.memoryMaxMb.signoz;
      OBS_MEMMAX_GLITCHTIP = toString cfg.memoryMaxMb.glitchtip;
    };
    text = builtins.readFile ./observability/observability.sh;
  };

  # The stack is about 1.5 GB of store paths. A shell that never runs `up` should
  # not pay for it, so the devenv script holds only the derivation and realises it
  # on first use. The discard keeps the path a dependency on the .drv alone.
  implDrv = builtins.unsafeDiscardOutputDependency impl.drvPath;
in
{
  options.observability = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Provide the `observability` command. It starts nothing until it is run.";
    };
    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Days of traces, metrics, logs and GlitchTip events to keep.";
    };
    spanMetrics = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the collector's span-metrics processor and tell SigNoz to read it.
        Off saves a processor and a metrics write path; SigNoz's Services page then
        reads the trace tables. The one switch for that choice.
      '';
    };
    rootEmail = lib.mkOption {
      type = lib.types.str;
      default = "admin@example.com";
      description = "The sign-in for both tools. Its password is generated per environment.";
    };
    organization = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Organization name in SigNoz and GlitchTip.";
    };
    appEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra variables written to the env file, for the application under observation.";
      example = { OTEL_SERVICE_NAME = "my_app"; };
    };
    budgetMb = lib.mkOption {
      type = lib.types.submodule {
        options = {
          clickhouse = lib.mkOption { type = lib.types.ints.positive; default = 800; };
          collector = lib.mkOption { type = lib.types.ints.positive; default = 250; };
          signoz = lib.mkOption { type = lib.types.ints.positive; default = 150; };
          glitchtip = lib.mkOption { type = lib.types.ints.positive; default = 300; };
          total = lib.mkOption { type = lib.types.ints.positive; default = 1500; };
        };
      };
      default = { };
      description = "Memory budget in MB that `observability status` reports against.";
    };
    memoryMaxMb = lib.mkOption {
      type = lib.types.submodule {
        options = {
          clickhouse = lib.mkOption { type = lib.types.ints.positive; default = 1200; };
          collector = lib.mkOption { type = lib.types.ints.positive; default = 400; };
          signoz = lib.mkOption { type = lib.types.ints.positive; default = 400; };
          glitchtip = lib.mkOption { type = lib.types.ints.positive; default = 450; };
        };
      };
      default = { };
      description = "Hard memory caps, applied only where systemd user scopes exist.";
    };
  };

  config = lib.mkIf cfg.enable {
    scripts.observability = {
      description = "SigNoz and GlitchTip: up, down, status, urls";
      exec =
        if supported then ''
          set -euo pipefail
          root="''${DEVENV_STATE:-${config.devenv.state}}/observability"
          ${pkgs.coreutils}/bin/mkdir -p "$root"
          out="$(${pkgs.nix}/bin/nix-store --realise ${implDrv} --add-root "$root/nix-root" 2> "$root/realise.log" | ${pkgs.coreutils}/bin/tail -n1)" || {
            ${pkgs.coreutils}/bin/cat "$root/realise.log" >&2
            exit 1
          }
          exec "$out/bin/observability-impl" "$@"
        '' else ''
          echo "observability: ${pkgs.stdenv.hostPlatform.system} is not supported (the SigNoz releases cover linux amd64 and arm64)" >&2
          exit 1
        '';
    };

    # The app picks up the endpoints and the DSN by entering the shell.
    enterShell = ''
      if [ -f "''${DEVENV_STATE:-${config.devenv.state}}/observability/env" ]; then
        . "''${DEVENV_STATE:-${config.devenv.state}}/observability/env"
      fi
    '';
  };
}
