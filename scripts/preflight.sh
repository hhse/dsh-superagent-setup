#!/bin/sh
# Preflight for a dsh-superagent install. Read-only: it checks, it changes nothing.
# Usage: ./scripts/preflight.sh [agent-cli-path]

set -u
fails=0
notes=""

ok()   { printf '  ok    %-14s %s\n' "$1" "$2"; }
bad()  { printf '  FAIL  %-14s %s\n' "$1" "$2"; fails=$((fails + 1)); }
warn() { printf '  warn  %-14s %s\n' "$1" "$2"; }

version_at_least() { # actual required
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".");
    for (i = 1; i <= 3; i++) {
      xi = (i <= na) ? x[i] + 0 : 0; yi = (i <= nb) ? y[i] + 0 : 0;
      if (xi > yi) exit 0; if (xi < yi) exit 1;
    }
    exit 0;
  }'
}

echo "dsh-superagent preflight"
echo

# Node 22.19+ or 24+
if v=$(node -v 2>/dev/null); then
  n=${v#v}; major=${n%%.*}; rest=${n#*.}
  if [ "$major" -eq 22 ] && version_at_least "$rest" "19.0"; then ok node "$v"
  elif [ "$major" -ge 24 ]; then ok node "$v"
  else bad node "$v (need 22.19+ or 24+)"; fi
else bad node "not found"; fi

# pnpm
if v=$(pnpm -v 2>/dev/null); then ok pnpm "$v"; else bad pnpm "not found (npm i -g pnpm)"; fi

# git 2.32+
if v=$(git --version 2>/dev/null); then
  n=$(printf '%s' "$v" | awk '{print $3}')
  if version_at_least "$n" "2.32.0"; then ok git "$n"; else bad git "$n (need 2.32+)"; fi
else bad git "not found"; fi

# tmux, needed only to run the service
if v=$(tmux -V 2>/dev/null); then ok tmux "$v"; else bad tmux "not found (brew install tmux)"; fi

# python3 for the service script
if v=$(python3 --version 2>/dev/null); then ok python3 "${v#Python }"; else bad python3 "not found"; fi

# gh 2.48+
if v=$(gh --version 2>/dev/null | head -1); then
  n=$(printf '%s' "$v" | awk '{print $3}')
  if version_at_least "$n" "2.48.0"; then ok gh "$n"; else bad gh "$n (need 2.48+)"; fi
else bad gh "not found"; fi

# dsh CLI inside the bundle's engines range
if v=$(dsh --version 2>/dev/null); then
  case "$v" in
    0.2.*) ok dsh "$v" ;;
    *) warn dsh "$v (bundle wants ^0.2.1-alpha.2; 0.2.1-rc.3 is verified)" ;;
  esac
else bad dsh "not found (npm i -g @deepseek-ai/dsh@0.2.1-rc.3)"; fi

echo

# operator identity
if login=$(gh api user --jq .login 2>/dev/null); then ok "operator" "$login"
else bad "operator" "gh is not signed in, or the network is down"; fi

# agent identity, through the wrapper
agent_cli=${1:-"$HOME/.local/bin/gh-agent"}
if [ -x "$agent_cli" ]; then
  if alogin=$("$agent_cli" api user --jq .login 2>/dev/null); then
    ok "agent cli" "$alogin"
    [ "${login:-}" = "$alogin" ] && warn "agent cli" "same login as the operator; the agent needs its own account"
  else
    bad "agent cli" "$agent_cli cannot read its account ($agent_cli auth login)"
  fi
else
  bad "agent cli" "$agent_cli missing or not executable"
fi

# existing profile
if [ -f "$HOME/.dsh/profiles/superagent/cordis.patch.yml" ]; then
  warn "profile" "superagent already exists; upgrade it instead of recreating it"
else
  ok "profile" "superagent is free"
fi

# network shape
if command -v nslookup >/dev/null 2>&1; then
  addr=$(nslookup github.com 2>/dev/null | awk '/^Address/ && !/#/ {print $NF; exit}')
  case "${addr:-}" in
    198.18.*|198.19.*) warn "network" "github.com resolves to $addr (proxy fake IP); expect intermittent EOF, retry" ;;
  esac
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "preflight: ready"
else
  echo "preflight: $fails blocking problem(s)"
  exit 1
fi
