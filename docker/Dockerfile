# DevLead server image (F1: S7-S10, S12, S15, S20). Built locally by
# compose.yaml from this repository; .env.example lists the runtime settings.
#
# Nothing here floats: the base image is pinned by digest, Claude Code by
# version, and the two binaries downloaded below by version and SHA-256. To
# update one, change it here and rebuild.
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
# The container runs as the host user (S9, and S14 later): compose passes the
# host UID/GID. Root is refused.
ARG DEVLEAD_UID=1000
ARG DEVLEAD_GID=1000

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git iptables jq procps shellcheck tini util-linux \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) gh_sha="$GH_SHA256_AMD64"; yq_sha="$YQ_SHA256_AMD64" ;; \
      arm64) gh_sha="$GH_SHA256_ARM64"; yq_sha="$YQ_SHA256_ARM64" ;; \
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
    rm -rf "$tmp"; \
    gh --version; yq --version

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
COPY docker/entrypoint.sh docker/init-firewall.sh /opt/devlead/docker/
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
#                           repo's own (GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM)
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
#                           keybindings). Only Claude Code's runtime state is
#                           the user's: .claude.json and the session, project
#                           history, snapshot and backup directories.
#   ~/.devlead              root:root 0755. scripts and hooks are root-owned
#                           links to /opt/devlead, so the paths the scripts
#                           use ($HOME/.devlead/scripts/...) keep working. The
#                           state subdirectories, inbox.tsv and inbox.read.tsv
#                           are the user's; notify.env is written at start.
#                           F3 (S14) mounts the host's state over them.
RUN set -eux; \
    install -d -m 0755 -o root -g root /etc/devlead; \
    printf '%s\n' 'DevLead server image: guard.sh is always on (see .claude/hooks/guard.sh).' \
      > /etc/devlead/server-mode; \
    git config --file /etc/devlead/gitconfig credential.https://github.com.helper ''; \
    git config --file /etc/devlead/gitconfig --add credential.https://github.com.helper '!/usr/local/bin/gh auth git-credential'; \
    chown -R root:root /opt/devlead /etc/claude-code /etc/devlead; \
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
    chown "$DEVLEAD_UID:$DEVLEAD_GID" /home/devlead/.claude/.claude.json; \
    chmod 0600 /home/devlead/.claude/.claude.json

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
# F1: stay alive; the healthcheck watches the firewall. F2 (S11) replaces this
# with supercronic.
CMD ["sleep", "infinity"]
