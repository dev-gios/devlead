#!/usr/bin/env bash
# init-firewall.sh — default-deny egress for the DevLead container (S8).
#
#   init-firewall.sh            build the allowlist and apply it
#   init-firewall.sh --check    exit 0 only while the default-deny policy holds
#                               (the compose healthcheck)
#
# Runs as root from entrypoint.sh, BEFORE privileges are dropped. Every failure
# exits non-zero and the entrypoint then refuses to start: the agent never
# runs on an open network (fail closed).
#
# What may leave the container (IPv4, TCP 443 unless a port is given):
#   - loopback, which includes Docker's embedded DNS on 127.0.0.11
#   - replies on connections that were allowed (ESTABLISHED,RELATED)
#   - DNS (udp/tcp 53) to the nameservers in /etc/resolv.conf. Docker's
#     embedded resolver (127.0.0.11) forwards each query to the host's DNS
#     from inside this network namespace, through a socket owned by root, so
#     root may send DNS to any server; the devlead user (UID != 0) reaches
#     only the resolvers resolv.conf names
#   - Anthropic: the API and the auth hosts Claude Code needs
#     (https://code.claude.com/docs/en/network-config)
#   - GitHub: the web, api and git ranges GitHub publishes at
#     https://api.github.com/meta, plus the download hosts (codeload, uploads,
#     *.githubusercontent.com), resolved here
#   - the ntfy host of DEVLEAD_NTFY_URL, when it is set
#   - every entry of DEVLEAD_EGRESS_ALLOW: "host" or "host:port", separated by
#     commas or spaces. Package registries go here. A host may be an IPv4
#     address; address ranges are not accepted.
# Everything else is rejected, and IPv6 is closed except for loopback.
#
# Names are resolved once, when this runs. An address that changes later is
# picked up when the container restarts.
#
# An allowlist entry that cannot be parsed or resolved is fatal, not skipped:
# a typo should stop the container with its name, not fail a run at night.
#
# The ruleset is loaded with iptables-restore, which replaces the filter table
# only. The nat table, where Docker keeps the rules of its embedded DNS, is
# left alone.
#
# Startup self-test: once the rules are in place https://example.com must be
# unreachable. Do not add example.com to DEVLEAD_EGRESS_ALLOW.
#
# Written for DevLead from the approach Anthropic documents for its reference
# dev container (an iptables allowlist of resolved addresses); no code from
# that container is reused.
set -euo pipefail

PROBE_URL="https://example.com"

log() { printf 'devlead-firewall: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

ANTHROPIC_HOSTS=(api.anthropic.com claude.ai platform.claude.com)
GITHUB_HOSTS=(github.com api.github.com codeload.github.com uploads.github.com
              objects.githubusercontent.com raw.githubusercontent.com
              release-assets.githubusercontent.com)
GITHUB_META_URL="https://api.github.com/meta"

# --- Checks -------------------------------------------------------------------

# _policy_holds <iptables|ip6tables> — the three built-in chains default to DROP
# and OUTPUT ends in a REJECT.
_policy_holds() {
  local bin="$1" rules
  rules="$("$bin" -w -S 2>/dev/null)" || return 1
  grep -qx -- '-P INPUT DROP' <<<"$rules" || return 1
  grep -qx -- '-P FORWARD DROP' <<<"$rules" || return 1
  grep -qx -- '-P OUTPUT DROP' <<<"$rules" || return 1
  [[ "$(grep -- '^-A OUTPUT ' <<<"$rules" | tail -n 1)" == "-A OUTPUT -j REJECT"* ]]
}

_has_ipv6() { [[ -e /proc/net/if_inet6 ]]; }

check() {
  _policy_holds iptables || return 1
  if _has_ipv6; then _policy_holds ip6tables || return 1; fi
  return 0
}

if [[ "${1:-}" == "--check" ]]; then
  check
  exit $?
fi
[[ $# -eq 0 ]] || die "usage: init-firewall.sh [--check]"

[[ "$(id -u)" -eq 0 ]] || die "must run as root"
for _bin in iptables iptables-restore getent curl jq; do
  command -v "$_bin" >/dev/null 2>&1 || die "$_bin is not installed"
done

# --- Allowlist ----------------------------------------------------------------

_valid_ipv4() {
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' o
  [[ "$1" =~ $re ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

_valid_cidr4() {
  [[ "$1" == */* ]] || return 1
  local ip="${1%/*}" len="${1#*/}"
  _valid_ipv4 "$ip" && [[ "$len" =~ ^[0-9]{1,2}$ ]] && (( 10#$len <= 32 ))
}

_valid_hostname() {
  local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
  local re="^${label}(\\.${label})+\$"
  [[ ${#1} -le 253 && "$1" =~ $re ]]
}

_valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

ALLOW=()      # "<ipv4 or cidr> <port>"
HOSTS=()      # names, for the log line

# _allow_host <host> <port> — an IPv4 address as is, a name by its addresses.
_allow_host() {
  local host="$1" port="$2" ips ip
  _valid_port "$port" || die "invalid port '$port' for $host"
  if _valid_ipv4 "$host"; then
    ALLOW+=("$host $port")
    HOSTS+=("$host:$port")
    return 0
  fi
  _valid_hostname "$host" || die "'$host' is not a valid host name"
  ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)" || true
  [[ -n "$ips" ]] || die "cannot resolve $host"
  while IFS= read -r ip; do
    _valid_ipv4 "$ip" || die "$host resolved to '$ip', which is not an IPv4 address"
    ALLOW+=("$ip $port")
  done <<<"$ips"
  HOSTS+=("$host:$port")
}

for _h in "${ANTHROPIC_HOSTS[@]}" "${GITHUB_HOSTS[@]}"; do
  _allow_host "$_h" 443
done

# GitHub's published ranges. A failed fetch is fatal: without them git and gh
# would break on the first address GitHub rotates to.
_meta="$(curl -fsS --max-time 20 "$GITHUB_META_URL")" || die "cannot fetch $GITHUB_META_URL"
_ranges="$(jq -r '(.web + .api + .git)[]' <<<"$_meta" 2>/dev/null)" \
  || die "$GITHUB_META_URL did not return the expected JSON"
_n_ranges=0
while IFS= read -r _r; do
  [[ -n "$_r" && "$_r" != *:* ]] || continue        # IPv6 stays closed
  _valid_cidr4 "$_r" || die "$GITHUB_META_URL returned an invalid range '$_r'"
  ALLOW+=("$_r 443")
  _n_ranges=$((_n_ranges + 1))
done <<<"$_ranges"
(( _n_ranges > 0 )) || die "$GITHUB_META_URL returned no IPv4 ranges"

# ntfy. The URL carries the topic, which is a secret: only its host is logged.
if [[ -n "${DEVLEAD_NTFY_URL:-}" ]]; then
  _re='^https://([^/:?#@[:space:]]+)(:([0-9]+))?(/|$)'
  [[ "$DEVLEAD_NTFY_URL" =~ $_re ]] \
    || die "DEVLEAD_NTFY_URL is not an https://host[:port]/topic URL"
  _allow_host "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-443}"
fi

# Extra hosts.
if [[ -n "${DEVLEAD_EGRESS_ALLOW:-}" ]]; then
  read -ra _extra <<<"${DEVLEAD_EGRESS_ALLOW//,/ }"
  for _e in "${_extra[@]}"; do
    if [[ "$_e" == *:* ]]; then
      _allow_host "${_e%:*}" "${_e##*:}"
    else
      _allow_host "$_e" 443
    fi
  done
fi

# Nameservers.
NAMESERVERS=()
while read -r _kw _ns _; do
  [[ "$_kw" == "nameserver" ]] || continue
  _valid_ipv4 "$_ns" && NAMESERVERS+=("$_ns")
done < /etc/resolv.conf
(( ${#NAMESERVERS[@]} > 0 )) || die "no IPv4 nameserver in /etc/resolv.conf"

# --- Apply ----------------------------------------------------------------------

_ruleset4() {
  local ns dst port
  echo "*filter"
  echo ":INPUT DROP [0:0]"
  echo ":FORWARD DROP [0:0]"
  echo ":OUTPUT DROP [0:0]"
  echo "-A INPUT -i lo -j ACCEPT"
  echo "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
  echo "-A OUTPUT -o lo -j ACCEPT"
  echo "-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
  echo "-A OUTPUT -p udp -m udp --dport 53 -m owner --uid-owner 0 -j ACCEPT"
  echo "-A OUTPUT -p tcp -m tcp --dport 53 -m owner --uid-owner 0 -j ACCEPT"
  for ns in "${NAMESERVERS[@]}"; do
    echo "-A OUTPUT -d $ns/32 -p udp -m udp --dport 53 -j ACCEPT"
    echo "-A OUTPUT -d $ns/32 -p tcp -m tcp --dport 53 -j ACCEPT"
  done
  while read -r dst port; do
    [[ "$dst" == */* ]] || dst="$dst/32"
    echo "-A OUTPUT -d $dst -p tcp -m tcp --dport $port -j ACCEPT"
  done < <(printf '%s\n' "${ALLOW[@]}" | sort -u)
  echo "-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited"
  echo "COMMIT"
}

_ruleset6() {
  echo "*filter"
  echo ":INPUT DROP [0:0]"
  echo ":FORWARD DROP [0:0]"
  echo ":OUTPUT DROP [0:0]"
  echo "-A INPUT -i lo -j ACCEPT"
  echo "-A OUTPUT -o lo -j ACCEPT"
  echo "-A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited"
  echo "COMMIT"
}

_ruleset4 | iptables-restore -w || die "iptables-restore failed (does the container have NET_ADMIN?)"
if _has_ipv6; then
  command -v ip6tables-restore >/dev/null 2>&1 || die "ip6tables-restore is not installed"
  _ruleset6 | ip6tables-restore -w || die "ip6tables-restore failed"
fi

check || die "the default-deny policy is not in place after applying it"

# The self-test proves something only if the name resolves: a broken DNS would
# make any URL unreachable.
getent ahostsv4 "${PROBE_URL#https://}" >/dev/null 2>&1 \
  || die "cannot resolve ${PROBE_URL#https://}, so the firewall self-test cannot run"
if curl -fsS --max-time 5 -o /dev/null "$PROBE_URL" 2>/dev/null; then
  die "$PROBE_URL is still reachable — the egress firewall is not effective"
fi

log "egress allowed to $(printf '%s\n' "${ALLOW[@]}" | sort -u | wc -l | tr -d ' ') destinations: ${HOSTS[*]} and the GitHub ranges ($_n_ranges listed); DNS via ${NAMESERVERS[*]}"
