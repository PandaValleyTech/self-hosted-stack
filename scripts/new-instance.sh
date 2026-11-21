#!/usr/bin/env bash
# Create another instance of an app stack: <stack>/instances/<name>/.
#
#   scripts/new-instance.sh <stack> <name>      e.g. scripts/new-instance.sh immich family
#
# The instance includes <stack>/compose.yaml, so there's one stack definition
# and any number of instances. It gets its own Compose project
# (<stack>-<name>), container names, private network, .env and data/.
# instances/ is gitignored.
#
# A stack supports instances when every container_name in its compose.yaml
# starts with ${<APP>_INSTANCE:-<app>} (and internal hostnames use it too).
# Singletons, of which a host has exactly one, never get instances.
set -euo pipefail

SINGLETONS=(npm authentik)

usage() { echo "usage: $(basename "$0") <stack> <name>" >&2; exit 2; }
die()   { echo "error: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || usage
stack=${1%/}
name=$2

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stack_dir=$root/$stack
dir=$stack_dir/instances/$name
project=$stack-$name
# immich -> IMMICH_INSTANCE, my-app -> MY_APP_INSTANCE
var=$(printf '%s' "$stack" | tr '[:lower:]-' '[:upper:]_')_INSTANCE

[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] \
  || die "instance name must be lowercase letters, digits and dashes: '$name'"
for s in "${SINGLETONS[@]}"; do
  [[ $stack != "$s" ]] || die "'$stack' is a singleton (one per host) and can't have instances"
done
[[ -f $stack_dir/compose.yaml && -f $stack_dir/.env.example ]] \
  || die "'$stack' is not a stack (no compose.yaml/.env.example in $stack_dir)"
# Every container name must come from the instance variable, or the new
# instance's containers would collide with the default instance's.
names=$(grep -E '^[[:space:]]*container_name:' "$stack_dir/compose.yaml" || true)
[[ -n $names ]] || die "'$stack' has no container_name entries in compose.yaml"
fixed=$(grep -vF "\${$var:-" <<<"$names" | sed -E 's/^[[:space:]]*container_name:[[:space:]]*//' || true)
[[ -z $fixed ]] || die "'$stack' isn't instance-ready: container names must start with \${$var:-$stack}, found: $(tr '\n' ' ' <<<"$fixed")"
[[ ! -e $dir ]] || die "$dir already exists"

mkdir -p "$dir"

cat > "$dir/compose.yaml" <<EOF
# Instance '$name' of $stack, created by scripts/new-instance.sh.
# The stack is defined in ../../compose.yaml; relative paths in it (./data)
# resolve to this directory. Add a compose.override.yaml here for
# host-specific changes (see ../../compose.override.example.yaml).
name: $project

include:
  - path: ../../compose.yaml
    project_directory: .
EOF

cat > "$dir/.envrc" <<'EOF'
# Repo root (APP_NETWORK, TZ), then this instance's .env. Skips the stack's
# own .envrc on purpose: shell variables override .env in Compose, so values
# from the default instance (e.g. an upload path) would leak into this one.
source_env_if_exists ../../../.envrc
dotenv_if_exists .env
EOF

# .env from the stack's example: set the instance name and fill empty secrets.
generated=()
set_var=false
{
  echo "# Instance '$name' of $stack, created by scripts/new-instance.sh."
  echo "# Set every value here: nothing is inherited from $stack/.env. Never"
  echo "# share data or upload paths with another instance."
  echo
  while IFS= read -r line || [[ -n $line ]]; do
    key=${line%%=*}
    if [[ $line == "$var="* ]]; then
      echo "$var=$project"
      set_var=true
    elif [[ $line =~ ^[A-Z0-9_]*(PASS|PASSWORD|SECRET|SECRET_KEY)=$ ]]; then
      # Hex: safe for every app here (Immich wants letters and digits only).
      echo "$key=$(openssl rand -hex 32)"
      generated+=("$key")
    else
      echo "$line"
    fi
  done < "$stack_dir/.env.example"
  $set_var || printf '\n# Prefix for container names (set by scripts/new-instance.sh).\n%s=%s\n' "$var" "$project"
} > "$dir/.env"
chmod 600 "$dir/.env"

rel=${dir#"$root"/}
echo "Created $rel (Compose project '$project', containers '$project*')."
if ((${#generated[@]})); then
  echo "Generated: ${generated[*]}"
fi
cat <<EOF

Next:
  1. Review $rel/.env (paths, URLs, client IDs; see $stack/README.md).
  2. cd $rel && direnv allow
  3. docker compose up -d
  4. Add an NPM proxy host for the instance's own hostname, forwarding to its
     $project* container, and its own Authentik provider/application.
EOF
