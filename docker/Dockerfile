# DevLead server image (F1: S7-S10, S12, S15, S20; F2: S11, S16-S19). Built
# locally by compose.yaml from this repository; docker/devlead.env.example
# lists the runtime settings.
#
# Nothing here floats: the base image is pinned by digest, its Debian packages
# by the Debian snapshot it was built from, Claude Code by version, and the
# three binaries downloaded below by version and SHA-256. To update one,
# change it here and rebuild.
FROM node:24-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0

# Claude Code, pinned (S15). Updated only by rebuilding the image.
ARG CLAUDE_CODE_VERSION=2.1.326
# GitHub CLI and mikefarah/yq (the yq DevLead's scripts use), checked against
# the SHA-256 sums their releases publish.
ARG GH_VERSION=2.103.3
ARG GH_SHA256_AMD64=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG GH_SHA256_ARM64=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
ARG YQ_VERSION=v4.54.1
ARG YQ_SHA256_AMD64=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
ARG YQ_SHA256_ARM64=189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b
# supercronic, the scheduler (S11): the SHA-256 GitHub publishes for each
# release asset.
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA256_AMD64=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
ARG SUPERCRONIC_SHA256_ARM64=4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94
# The Debian snapshot the base image was built from (its apt sources record
# it). Packages come from that snapshot, so a rebuild installs the same
# versions; the build stops if the base image moves to another one.
ARG DEBIAN_SNAPSHOT=20261104T212339Z
# The container runs as the host user (S9, and S14 later): compose passes the
# host UID/GID. Root is refused.
ARG DEVLEAD_UID=1000
ARG DEVLEAD_GID=1000

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    src=/etc/apt/sources.list.d/debian.sources; \
    if ! grep -qF "snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT" "$src"; then \
      echo "the base image was built from another Debian snapshot than DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT — set it to the one $src names" >&2; exit 1; \
    fi; \
    sed -i \
      -e "s|^URIs: http://deb.debian.org/debian-security\$|URIs: http://snapshot.debian.org/archive/debian-security/$DEBIAN_SNAPSHOT|" \
      -e "s|^URIs: http://deb.debian.org/debian\$|URIs: http://snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT|" \
      -e "/^Signed-By:/a Check-Valid-Until: no" "$src"; \
    if grep -q 'deb.debian.org' "$src"; then echo "$src still names deb.debian.org" >&2; exit 1; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git iptables jq procps shellcheck tini tzdata util-linux; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) gh_sha="$GH_SHA256_AMD64"; yq_sha="$YQ_SHA256_AMD64"; sc_sha="$SUPERCRONIC_SHA256_AMD64" ;; \
      arm64) gh_sha="$GH_SHA256_ARM64"; yq_sha="$YQ_SHA256_ARM64"; sc_sha="$SUPERCRONIC_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "$tmp/gh.tar.gz" \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz"; \
    echo "$gh_sha  $tmp/gh.tar.gz" | sha256sum -c -; \
    tar -xzf "$tmp/gh.tar.gz" -C "$tmp"; \
    install -m 0755 "$tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh; \
    curl -fsSL -o "$tmp/yq" \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"; \
    echo "$yq_sha  $tmp/yq" | sha256sum -c -; \
    install -m 0755 "$tmp/yq" /usr/local/bin/yq; \
    curl -fsSL -o "$tmp/supercronic" \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${arch}"; \
    echo "$sc_sha  $tmp/supercronic" | sha256sum -c -; \
    install -m 0755 "$tmp/supercronic" /usr/local/bin/supercronic; \
    rm -rf "$tmp"; \
    gh --version; yq --version; supercronic -version

RUN npm install -g --no-fund --no-audit "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version | grep -qF "$CLAUDE_CODE_VERSION"

# The devlead user, with the host's UID/GID. The base image's node user holds
# 1000, the usual host UID, so it goes.
RUN set -eux; \
    if [ "$DEVLEAD_UID" -le 0 ] || [ "$DEVLEAD_GID" -le 0 ]; then \
      echo "DEVLEAD_UID and DEVLEAD_GID must be non-zero: the container never runs as root" >&2; exit 1; \
    fi; \
    userdel -r node; \
    if getent passwd "$DEVLEAD_UID" >/dev/null; then \
      echo "UID $DEVLEAD_UID is already used in the image: $(getent passwd "$DEVLEAD_UID" | cut -d: -f1)" >&2; exit 1; \
    fi; \
    getent group "$DEVLEAD_GID" >/dev/null || groupadd -g "$DEVLEAD_GID" devlead; \
    useradd -u "$DEVLEAD_UID" -g "$DEVLEAD_GID" -M -d /home/devlead -s /bin/bash devlead

# DevLead itself, read-only (S9): root owns every file, nobody else can write.
COPY .devlead/scripts/ /opt/devlead/scripts/
COPY .devlead/bin/devlead /opt/devlead/bin/devlead
COPY .claude/hooks/ /opt/devlead/hooks/
COPY .claude/commands/ /opt/devlead/commands/
COPY docker/entrypoint.sh docker/init-firewall.sh docker/claude-wrapper.sh \
     docker/runner-config.sh docker/run-job.sh docker/sync-repos.sh /opt/devlead/docker/
# Hooks, deny rules and the bypass lock (S9): Claude Code's highest-precedence
# settings, readable by the session (a file it cannot read is ignored) and
# writable by root only.
COPY docker/managed-settings.json /etc/claude-code/managed-settings.json

# Layout. The agent must not be able to swap what it runs, nor leave behind
# anything that the next session reads as configuration:
#   /opt/devlead            root:root, files 0644, scripts 0755
#   /etc/claude-code        root:root; DevLead's commands are installed here as
#                           enterprise skills (/sweep-execute and the rest)
#   /etc/devlead            root:root. server-mode: the marker that keeps
#                           guard.sh on whatever the environment says.
#                           gitconfig: git's only config file besides each
#                           repo's own (GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM).
#                           It includes git-identity, the commits' author,
#                           written at start from DEVLEAD_GIT_NAME and
#                           DEVLEAD_GIT_EMAIL.
#                           install-stamp: the source revision and the SHA-256
#                           of every installed file (doctor.sh checks it).
#                           crontab, runner.conf and repos: the schedule, the
#                           session limits and the enrolled repos, written by
#                           the entrypoint at start from the env file
#                           (docker/runner-config.sh)
#   /var/lib/devlead        root:root 0755, made by the entrypoint: the
#                           session ledger (the user's, so the claude wrapper
#                           can record sessions, but it cannot be removed or
#                           replaced) and the root-owned lock files
#   /home/devlead           root:root 0755: the user writes nothing directly
#                           in it, so it cannot create ~/.gitconfig,
#                           ~/.config/git or ~/.claude.json
#   ~/.bashrc and the other shell startup files
#                           root-owned and empty: a session cannot plant a
#                           function that shadows `bash` in the next one
#   ~/.cache                the user's (caches, gate-check.sh's test cache)
#   ~/.claude               CLAUDE_CONFIG_DIR, root:root 0755. Its settings
#                           files, CLAUDE.md and the agents/, commands/,
#                           skills/, hooks/, output-styles/, plugins/, rules/,
#                           workflows/, agent-memory/ and themes/ directories
#                           are root-owned and empty, and nothing else can be
#                           created next to them (no cached server policy, no
#                           keybindings). .claude.json is root-owned too: Claude
#                           Code reads an env block from it, so a session could
#                           otherwise hand the next one its variables; it runs
#                           without saving that state. Only the session,
#                           project history, snapshot and backup directories
#                           are the user's.
#   /usr/local/bin/claude   the wrapper (docker/claude-wrapper.sh): every
#                           session loads only the user and managed settings,
#                           never the project or local settings of the clone
#   ~/.devlead              root:root 0755. scripts and hooks are root-owned
#                           links to /opt/devlead, so the paths the scripts
#                           use ($HOME/.devlead/scripts/...) keep working. The
#                           state subdirectories, inbox.tsv and inbox.read.tsv
#                           are the user's; notify.env is written at start.
#                           audit/ holds the run log (S18). Only root can
#                           create or remove ~/.devlead/PAUSE, the global
#                           pause (S17), or autonomous-repos, the fleet list
#                           the entrypoint writes from DEVLEAD_REPOS (S13).
#                           compose mounts the host's state over them (S14):
#                           agenda, audit, decisions, journals, learn
#                           (read-only), outcomes, reports, run-state and the
#                           two inbox files. profile/ and run/ stay the
#                           container's; nothing else of the host's ~/.devlead
#                           (gh-token, notify.env, loop.env) is mounted.
#   DEVLEAD_WORKSPACE       the clones volume (S13), at the host path that
#                           holds the enrolled repos: each clone sits at its
#                           repo's host path. Root owns it and every directory
#                           above a clone; docker/sync-repos.sh resets each
#                           clone to origin's default branch before a job
RUN set -eux; \
    install -d -m 0755 -o root -g root /etc/devlead; \
    printf '%s\n' 'DevLead server image: guard.sh is always on (see .claude/hooks/guard.sh).' \
      > /etc/devlead/server-mode; \
    git config --file /etc/devlead/gitconfig credential.https://github.com.helper ''; \
    git config --file /etc/devlead/gitconfig --add credential.https://github.com.helper '!/usr/local/bin/gh auth git-credential'; \
    git config --file /etc/devlead/gitconfig include.path /etc/devlead/git-identity; \
    chown -R root:root /opt/devlead /etc/claude-code /etc/devlead; \
    real_claude=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe; \
    [ "$(readlink -f /usr/local/bin/claude)" = "$real_claude" ]; \
    rm /usr/local/bin/claude; \
    install -m 0755 -o root -g root /opt/devlead/docker/claude-wrapper.sh /usr/local/bin/claude; \
    "$real_claude" --version | grep -qF "$CLAUDE_CODE_VERSION"; \
    [ "$(command -v claude)" = /usr/local/bin/claude ] && [ "$(type -ap claude | wc -l)" -eq 1 ]; \
    claude --version | grep -qF "$CLAUDE_CODE_VERSION"; \
    for f in /opt/devlead/commands/*.md; do \
      name="$(basename "$f" .md)"; \
      install -D -m 0644 "$f" "/etc/claude-code/.claude/skills/$name/SKILL.md"; \
    done; \
    find /opt/devlead /etc/claude-code /etc/devlead -type d -exec chmod 0755 {} +; \
    find /opt/devlead /etc/claude-code /etc/devlead -type f -exec chmod 0644 {} +; \
    chmod 0755 /opt/devlead/scripts/*.sh /opt/devlead/hooks/*.sh /opt/devlead/bin/devlead /opt/devlead/docker/*.sh; \
    ln -s /opt/devlead/bin/devlead /usr/local/bin/devlead; \
    install -d -m 0755 -o root -g root /home/devlead; \
    for f in .bashrc .bash_profile .bash_login .bash_logout .profile; do \
      install -m 0644 -o root -g root /dev/null "/home/devlead/$f"; \
    done; \
    install -d -m 0700 -o "$DEVLEAD_UID" -g "$DEVLEAD_GID" /home/devlead/.cache; \
    install -d -m 0755 -o root -g root /home/devlead/.devlead; \
    ln -s /opt/devlead/scripts /home/devlead/.devlead/scripts; \
    ln -s /opt/devlead/hooks /home/devlead/.devlead/hooks; \
    for d in agenda audit decisions journals learn outcomes profile reports run run-state; do \
      install -d -m 0700 -o "$DEVLEAD_UID" -g "$DEVLEAD_GID" "/home/devlead/.devlead/$d"; \
    done; \
    for f in inbox.tsv inbox.read.tsv; do \
      install -m 0600 -o "$DEVLEAD_UID" -g "$DEVLEAD_GID" /dev/null "/home/devlead/.devlead/$f"; \
    done; \
    install -d -m 0755 -o root -g root /home/devlead/.claude; \
    for f in settings.json settings.local.json; do \
      printf '{}\n' > "/home/devlead/.claude/$f"; \
    done; \
    : > /home/devlead/.claude/CLAUDE.md; \
    chmod 0644 /home/devlead/.claude/settings.json /home/devlead/.claude/settings.local.json /home/devlead/.claude/CLAUDE.md; \
    for d in agents commands skills hooks output-styles plugins rules workflows agent-memory themes; do \
      install -d -m 0755 -o root -g root "/home/devlead/.claude/$d"; \
    done; \
    for d in backups cache debug file-history paste-cache plans projects session-env sessions shell-snapshots tasks; do \
      install -d -m 0700 -o "$DEVLEAD_UID" -g "$DEVLEAD_GID" "/home/devlead/.claude/$d"; \
    done; \
    printf '{}\n' > /home/devlead/.claude/.claude.json; \
    chmod 0644 /home/devlead/.claude/.claude.json

# No user-writable directory on PATH, so neither the hooks nor the scripts can
# be handed a planted binary. DEVLEAD_GUARD=1 turns guard.sh on in every
# session started in this container, unattended or not; the server-mode marker
# keeps it on if a session's settings say otherwise, and the managed settings
# pin these variables for every session as well.
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    CLAUDE_CONFIG_DIR=/home/devlead/.claude \
    GIT_CONFIG_GLOBAL=/etc/devlead/gitconfig \
    GIT_CONFIG_NOSYSTEM=1 \
    DEVLEAD_GUARD=1

WORKDIR /home/devlead

# The entrypoint needs root for the firewall, then drops to devlead for good.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/devlead/docker/entrypoint.sh"]
# The install stamp (F1 follow-up a): what the build installed, and from which
# revision. compose.yaml passes DEVLEAD_SOURCE_REV, the commit you build from;
# without it doctor.sh reports STATUS: unknown and the unattended runs do not
# start. Declared here, at the end, so a new revision rebuilds only this layer.
ARG DEVLEAD_SOURCE_REV=
RUN set -eux; \
    case "$DEVLEAD_SOURCE_REV" in \
      "") echo "DEVLEAD_SOURCE_REV is not set: doctor.sh will report this image as unknown" >&2 ;; \
      *[!0-9a-f]*) echo "DEVLEAD_SOURCE_REV must be a git commit SHA (git rev-parse HEAD)" >&2; exit 1 ;; \
    esac; \
    if [ -n "$DEVLEAD_SOURCE_REV" ] && { [ "${#DEVLEAD_SOURCE_REV}" -lt 7 ] || [ "${#DEVLEAD_SOURCE_REV}" -gt 40 ]; }; then \
      echo "DEVLEAD_SOURCE_REV must be a git commit SHA (git rev-parse HEAD)" >&2; exit 1; \
    fi; \
    { echo "# DevLead server image install stamp: written by docker/Dockerfile at build time, checked by doctor.sh"; \
      echo "REVISION: $DEVLEAD_SOURCE_REV"; \
      echo "ROOT: /opt/devlead"; \
      echo "ROOT: /etc/claude-code"; \
      find /opt/devlead /etc/claude-code -type f -print0 | sort -z | xargs -0 sha256sum; \
      sha256sum /usr/local/bin/claude /usr/local/bin/supercronic /etc/devlead/server-mode /etc/devlead/gitconfig; \
    } > /etc/devlead/install-stamp; \
    chown root:root /etc/devlead/install-stamp; \
    chmod 0644 /etc/devlead/install-stamp

# The scheduler (S11), as the devlead user: the entrypoint writes the crontab
# from the env file, then drops to devlead and runs this. supercronic never
# makes up a run that was missed while the container was down.
CMD ["/usr/local/bin/supercronic", "-passthrough-logs", "/etc/devlead/crontab"]
