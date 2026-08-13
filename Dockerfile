# Multi-stage build producing a self-contained Elixir release.
#
# The two stages exist so the runtime image carries no compiler, no build tools
# and no source: a smaller image with a much smaller attack surface. What ships
# is the release plus the ERTS it was built against.
#
# Versions are pinned to the pairing devenv.nix and CI use. If those three ever
# disagree, "works locally" stops being evidence of anything.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250520-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# --- build -------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies are copied and fetched before the application source, so an
# application-only change reuses the cached dependency layer.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# config/config.exs and config/prod.exs are compile-time; runtime.exs is not,
# and is copied later so that changing it does not invalidate the dependency
# compilation layer.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Node is needed only if the A2UI client packages are in play. esbuild and
# tailwind are fetched as binaries by their mix tasks, so a full Node toolchain
# is not otherwise required.
RUN if [ -f assets/package.json ]; then \
      apt-get update -y && apt-get install -y nodejs npm \
      && npm --prefix assets ci \
      && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# --- runtime -----------------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# The BEAM wants a UTF-8 locale; without it, string handling misbehaves in ways
# that are tedious to diagnose.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Runs as a non-root user. A release needs no write access to its own files.
RUN chown nobody /app
ENV MIX_ENV="prod"
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/ash_enterprise ./
USER nobody

# Migrations are NOT run here. Running them from the application container means
# every replica races to migrate on rollout. Run them as a separate step:
#
#   bin/ash_enterprise eval "AshEnterprise.Release.migrate()"
#   bin/ash_enterprise eval "AshEnterprise.Release.seed_privileges()"
#
# See lib/ash_enterprise/release.ex.
CMD ["/app/bin/server"]
