# The Team Frontress dedicated server, as a container.
#
# This is the only supported way to run a game server for this site. Setting a
# machine up by hand -- steamcmd, the Steam Linux Runtime, TF2's content, the
# game payload, the configs, an agent to report results -- is six things to get
# right per machine; a host that can run a container is one.
#
# Four stages, so the expensive one is cached:
#
#   rcon-build      a tiny RCON client, for the healthcheck and shutdown
#   agent-build     greyline-agent, which reports matches to the coordinator
#   frontress-base  Ubuntu + steamcmd + Steam Linux Runtime + TF2 content
#   final           our own game payload, configs and entrypoint
#
# frontress-base is ~15GB of downloads and changes only when Valve ships TF2
# content; the payload on top of it changes every build. Build just the base
# with `--target frontress-base`, which is what CloudImageBuildWorker does to
# keep it out of the dangling-image sweep.

# ============================================================
# Stage: rcon-build
# ============================================================
FROM ubuntu:24.04 AS rcon-build
RUN apt-get update && apt-get install -y build-essential git cmake libglib2.0-dev \
    && git clone https://github.com/n0la/rcon.git /tmp/rcon \
    && cd /tmp/rcon && sed -i '/ADD_SUBDIRECTORY(tests)/d' CMakeLists.txt && cmake . && make \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================================
# Stage: agent-build
# ============================================================
# The agent lives in the game repository next to the coordinator it talks to.
# Only that one directory is fetched: the rest of the repo is the Source engine
# and is not worth downloading to build a 6MB binary.
FROM golang:1.24-bookworm AS agent-build
ARG FRONTRESS_REPO=https://github.com/gru2007/team-frontress.git
ARG FRONTRESS_REF=main
RUN git init /src \
    && cd /src \
    && git remote add origin "${FRONTRESS_REPO}" \
    && git config core.sparseCheckout true \
    && echo "services/coordinator/*" > .git/info/sparse-checkout \
    && git fetch --depth 1 origin "${FRONTRESS_REF}" \
    && git checkout FETCH_HEAD \
    && cd /src/services/coordinator \
    && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/greyline-agent ./cmd/greyline-agent

# ============================================================
# Stage: frontress-base
# ============================================================
FROM ubuntu:24.04 AS frontress-base

RUN echo steam steam/question select "I AGREE" | debconf-set-selections \
    && echo steam steam/license note '' | debconf-set-selections \
    && apt-get -y update \
    && apt-get -y install software-properties-common \
    && add-apt-repository --no-update multiverse \
    && dpkg --add-architecture i386 \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y install \
        libstdc++6 libcurl3-gnutls wget libncurses6 bzip2 unzip vim nano \
        lib32gcc-s1 lib32stdc++6 steamcmd \
        ca-certificates lib32z1 libncurses6:i386 libbz2-1.0:i386 \
        libtinfo6:i386 libcurl3-gnutls:i386 \
        openssh-server iptables curl sudo iproute2 locales jq \
    && locale-gen en_US.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && useradd -m frontress \
    && su frontress -c '/usr/games/steamcmd +quit' \
    && mkdir -p /run/sshd \
    && ssh-keygen -A \
    && echo "frontress ALL=(ALL) NOPASSWD: /sbin/iptables, /usr/sbin/iptables, /usr/sbin/sshd" > /etc/sudoers.d/frontress \
    && chmod 0440 /etc/sudoers.d/frontress

ENV HOME=/home/frontress
ENV USER=frontress
USER frontress
WORKDIR /home/frontress/hlserver

# What our payload needs underneath it, and neither of these is ours:
#
#   1628350  Steam Linux Runtime 3.0 (sniper). tc2.sh runs the server inside it.
#   232250   TF2's dedicated content, mounted by gameinfo as ../tf2/tf.
#
# Both are anonymous downloads. steamcmd occasionally fails the first attempt
# with 0x426, so each gets one retry.
RUN (/usr/games/steamcmd +force_install_dir /home/frontress/hlserver/SteamLinuxRuntime_sniper +login anonymous +app_update 1628350 validate +quit || \
     /usr/games/steamcmd +force_install_dir /home/frontress/hlserver/SteamLinuxRuntime_sniper +login anonymous +app_update 1628350 validate +quit) \
    && (/usr/games/steamcmd +force_install_dir /home/frontress/hlserver/tf2 +login anonymous +app_update 232250 +quit || \
        /usr/games/steamcmd +force_install_dir /home/frontress/hlserver/tf2 +login anonymous +app_update 232250 +quit) \
    # The server serves our maps, not TF2's, and the client downloads what it
    # is missing. Dropping them saves several gigabytes per host.
    && rm -f /home/frontress/hlserver/tf2/tf/maps/*.bsp

COPY --from=rcon-build --chown=frontress:frontress /tmp/rcon/rcon /home/frontress/hlserver/rcon

# ============================================================
# Stage: final
# ============================================================
FROM frontress-base

# The game payload. This is the artifact game_clean/copy_server.sh produces and
# the release workflow uploads -- the same bytes SteamPipe publishes to Tool
# AppID 5150320, in a form something that is not Steam can fetch.
#
# CACHEBUST is set per build so a new release is actually downloaded rather
# than served from the layer cache.
ARG FRONTRESS_SERVER_URL=https://github.com/gru2007/team-frontress/releases/latest/download/frontress-dedicated-linux.tar.gz
ARG FRONTRESS_VERSION=0
ARG CACHEBUST=0
RUN echo "Frontress build: ${FRONTRESS_VERSION} (cache bust ${CACHEBUST})" \
    && curl -fsSL "${FRONTRESS_SERVER_URL}" -o /tmp/frontress.tar.gz \
    && tar -xzf /tmp/frontress.tar.gz -C /home/frontress/hlserver \
    && rm /tmp/frontress.tar.gz \
    && test -f /home/frontress/hlserver/tc2/bin/linux64/server.so \
    && test "$(tr -d '\r\n ' < /home/frontress/hlserver/steam_appid.txt)" = "5147520" \
    && chmod +x /home/frontress/hlserver/tc2.sh \
                /home/frontress/hlserver/start_dedicated_tc2.sh \
                /home/frontress/hlserver/srcds_run_64 \
                /home/frontress/hlserver/tc2_linux64 \
                /home/frontress/hlserver/steamcmd_update.sh

# --chown, because everything after the base stage runs as frontress and a
# root-owned file here is one this stage cannot even chmod.
COPY --from=agent-build --chown=frontress:frontress /out/greyline-agent /home/frontress/hlserver/greyline-agent

# The rulesets a matchmade server execs, and anything else that has to be on
# every server. They come from the game repository (game/tc2/cfg) and are
# copied here so the image is self-contained.
COPY --chown=frontress:frontress base-configs/ /home/frontress/hlserver/tc2/

COPY --chown=frontress:frontress healthcheck.sh /home/frontress/hlserver/healthcheck.sh
COPY --chown=frontress:frontress entrypoint.sh /home/frontress/hlserver/entrypoint.sh
RUN chmod +x /home/frontress/hlserver/entrypoint.sh /home/frontress/hlserver/healthcheck.sh /home/frontress/hlserver/greyline-agent

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD /home/frontress/hlserver/healthcheck.sh

EXPOSE 27015/udp 27015/tcp 27020/udp 22/tcp

WORKDIR /home/frontress/hlserver

ENTRYPOINT ["./entrypoint.sh"]
CMD ["+maxplayers", "24"]
