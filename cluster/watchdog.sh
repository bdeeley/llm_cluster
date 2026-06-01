#!/usr/bin/env bash
# Ollama Cluster Watchdog
# Checks all configured remote nodes every 30s.
# Updates /etc/ollama-cluster/nodes.json with currently-online nodes.
# Also updates /etc/hosts so hostnames resolve.
#
# Configured nodes: listed in /etc/ollama-cluster/cluster.conf
# Format (one per line):
#   node-a  llm-node-a  192.168.1.0/24   # hostname and optional fixed IP or subnet hint

set -euo pipefail

CONF_DIR="/etc/ollama-cluster"
CONF_FILE="${CONF_DIR}/cluster.conf"
NODES_FILE="${CONF_DIR}/nodes.json"
HOSTS_MARKER="# llm-cluster-managed"

log() { echo "[$(date '+%H:%M:%S')] watchdog: $*" >&2; }

probe_node() {
    local node_name="$1" host="$2"
    # Try HTTP probe on Ollama port with 4s timeout
    local url="http://${host}:11434/api/tags"
    if curl -sf --connect-timeout 4 --max-time 6 "$url" -o /dev/null 2>/dev/null; then
        # Resolve IP for /etc/hosts
        local ip
        ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
        if [[ -z "$ip" ]]; then
            ip=$(curl -sf --connect-timeout 4 "http://${host}:11434" 2>/dev/null | true; \
                 python3 -c "import socket; print(socket.gethostbyname('${host}'))" 2>/dev/null || echo "")
        fi
        echo "UP ${ip}"
    else
        echo "DOWN"
    fi
}

update_hosts() {
    local node_name="$1" host="$2" ip="$3"
    # Remove existing managed entry for this host, then re-add
    local tmpfile
    tmpfile=$(mktemp)
    grep -v "^[0-9].*${host}.*${HOSTS_MARKER}" /etc/hosts > "$tmpfile" || true
    if [[ -n "$ip" ]]; then
        echo "${ip}  ${host}  ${HOSTS_MARKER} (${node_name})" >> "$tmpfile"
    fi
    cp "$tmpfile" /etc/hosts
    rm -f "$tmpfile"
}

rebuild_nodes_json() {
    # Rebuild JSON from current /etc/hosts + probe results
    # Called at the end with a collected map
    local json_args=("$@")  # pairs: name url name url ...
    local json='{"local":"http://localhost:11434"'
    local i=0
    while [[ $i -lt ${#json_args[@]} ]]; do
        local n="${json_args[$i]}"
        local u="${json_args[$((i+1))]}"
        json+=",\"${n}\":\"${u}\""
        i=$((i+2))
    done
    json+='}'
    echo "$json" > "${NODES_FILE}.tmp"
    mv "${NODES_FILE}.tmp" "$NODES_FILE"
}

run_once() {
    [[ -f "$CONF_FILE" ]] || { log "No cluster.conf found at $CONF_FILE"; return; }

    local online_pairs=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        local node_name host
        node_name=$(echo "$line" | awk '{print $1}')
        host=$(echo "$line" | awk '{print $2}')
        [[ -z "$node_name" || -z "$host" ]] && continue

        log "Probing ${node_name} (${host})…"
        local result
        result=$(probe_node "$node_name" "$host")
        local status ip=""

        status=$(echo "$result" | awk '{print $1}')
        if [[ "$status" == "UP" ]]; then
            ip=$(echo "$result" | awk '{print $2}')
            log "${node_name} ONLINE (${ip:-no-ip})"
            update_hosts "$node_name" "$host" "$ip"
            online_pairs+=("$node_name" "http://${host}:11434")
        else
            log "${node_name} OFFLINE"
            # Remove stale hosts entry
            update_hosts "$node_name" "$host" ""
        fi
    done < "$CONF_FILE"

    rebuild_nodes_json "${online_pairs[@]+"${online_pairs[@]}"}"
    log "nodes.json updated: $(cat "$NODES_FILE")"
}

# ── main ──────────────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR"

# Create default cluster.conf if missing
if [[ ! -f "$CONF_FILE" ]]; then
    cat > "$CONF_FILE" <<'EOF'
# Ollama cluster node definitions
# Format: <node-name>  <hostname-or-ip>
# Hostnames must be resolvable on your LAN (or set a fixed IP here).
#
node-a  llm-node-a
node-b  llm-node-b
EOF
    log "Created default $CONF_FILE — edit to match your network"
fi

# Write initial nodes.json if missing
[[ -f "$NODES_FILE" ]] || echo '{"local":"http://localhost:11434"}' > "$NODES_FILE"

if [[ "${1:-}" == "--once" ]]; then
    run_once
    exit 0
fi

log "Starting (poll interval: 30s)"
while true; do
    run_once
    sleep 30
done
