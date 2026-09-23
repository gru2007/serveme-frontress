# The Team Frontress dedicated server, as a container.
#
# This is the only supported way to run a game server for this site. Setting a
# machine up by hand -- steamcmd, the Steam Linux Runtime, the shared TF2
# assets, the game payload, the configs, an agent to report results -- is six
# things to get right per machine; a host that can run a container is one.
#
# Four stages, so the expensive one is cached:
#
#   rcon-build      a tiny RCON client, for the healthcheck and shutdown
#   agent-build     greyline-agent, which reports matches to the coordinator
#   frontress-base  Ubuntu + steamcmd + Steam Linux Runtime
#   final           our own game payload, configs and entrypoint
#
# TF2's large AppID 232250 depot deliberately is not an image layer. Each host
# keeps one copy in a named Docker volume, populated by update-tf2-assets.sh,
# and every reservation mounts that copy read-only.

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
#
# The ref matters. The game repository carries two matchmaking architectures on
# two branches, and only one of them has an agent:
#
#   mm    the coordinator drives the server over RCON (tf_mm_match_begin and
#         friends) and greyline-agent reports the result. This is what this
#         image, this site and tf2pickup are built against.
#   main  the game speaks to the coordinator itself over a native GC session.
#         services/coordinator/cmd/greyline-agent does not exist there, so a
#         build from that ref fails on the go build below.
#
# So this is pinned to mm rather than left on a branch name that happens to be
# the repository default.
FROM golang:1.24-bookworm AS agent-build
ARG FRONTRESS_REPO=https://github.com/gru2007/team-frontress.git
ARG FRONTRESS_REF=mm
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

# What our payload needs underneath it and is small enough to belong in the
# image:
#
#   1628350  Steam Linux Runtime 3.0 (sniper). tc2.sh runs the server inside it.
#
# It is an anonymous download. steamcmd occasionally fails the first attempt
# with 0x426, so it gets one retry. TF2 content itself is downloaded at deploy
# time into the host volume, never while this image is being built.
RUN (/usr/games/steamcmd +force_install_dir /home/frontress/hlserver/SteamLinuxRuntime_sniper +login anonymous +app_update 1628350 validate +quit || \
     /usr/games/steamcmd +force_install_dir /home/frontress/hlserver/SteamLinuxRuntime_sniper +login anonymous +app_update 1628350 validate +quit)

COPY --from=rcon-build --chown=frontress:frontress /tmp/rcon/rcon /home/frontress/hlserver/rcon
COPY --from=agent-build --chown=frontress:frontress /out/greyline-agent /home/frontress/hlserver/greyline-agent

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
#
# The launcher in the payload passes -enablefakeip unconditionally, which makes
# the engine answer on a Steam FakeIP instead of the address this site hands
# players. It comes out here, and again in entrypoint.sh, because a runtime
# update unpacks a fresh tc2.sh over this one.
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
                /home/frontress/hlserver/steamcmd_update.sh \
    && sed -i 's/[[:space:]]\{1,\}-enablefakeip\b//g' /home/frontress/hlserver/tc2.sh

# --chown, because everything after the base stage runs as frontress and a
# root-owned file here is one this stage cannot even chmod.
# The rulesets a matchmade server execs, and anything else that has to be on
# every server. They come from the game repository (game/tc2/cfg) and are
# copied here so the image is self-contained.
COPY --chown=frontress:frontress base-configs/ /home/frontress/hlserver/tc2/

COPY --chown=frontress:frontress healthcheck.sh /home/frontress/hlserver/healthcheck.sh
COPY --chown=frontress:frontress entrypoint.sh /home/frontress/hlserver/entrypoint.sh
COPY --chown=frontress:frontress update-tf2-assets.sh /home/frontress/hlserver/update-tf2-assets.sh
RUN chmod +x /home/frontress/hlserver/entrypoint.sh \
             /home/frontress/hlserver/healthcheck.sh \
             /home/frontress/hlserver/update-tf2-assets.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD /home/frontress/hlserver/healthcheck.sh

EXPOSE 27015/udp 27015/tcp 27020/udp 22/tcp

WORKDIR /home/frontress/hlserver

ENTRYPOINT ["./entrypoint.sh"]
CMD ["+maxplayers", "24"]
