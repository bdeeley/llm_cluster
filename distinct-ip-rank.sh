#!/bin/bash
set -euo pipefail

# Distinct-IP second-rank orchestrator for maxpower.
# This avoids same-IP ring path issues by running the local worker in a netns
# with a dedicated routable IP.
#
# Usage examples:
#   ./distinct-ip-rank.sh start
#   ./distinct-ip-rank.sh status
#   ./distinct-ip-rank.sh gate
#   ./distinct-ip-rank.sh stop
#
# Optional env overrides:
#   NS_NAME=exo-r1
#   NS_PARENT_IF=enp91s0
#   NS_IP=172.16.0.38
#   NS_CIDR=24
#   NS_GW=172.16.0.1
#   NS_API_PORT=52416
#   NS_LIBP2P_PORT=5680

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/node-config.env"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

MASTER_IP="${MASTER_IP:-172.16.0.28}"
MASTER_API_PORT="${MASTER_API_PORT:-52415}"
MASTER_LIBP2P_PORT="${MASTER_LIBP2P_PORT:-5678}"

# one remote is currently active in this repo topology
REMOTE_NODES="${REMOTE_NODES:-theplague:172.16.0.29:5679}"

EXO_BIN="${EXO_VENV:-/home/bdeeley/exo/.venv}/bin/exo"

NS_NAME="${NS_NAME:-exo-r1}"
NS_PARENT_IF="${NS_PARENT_IF:-enp91s0}"
NS_IP="${NS_IP:-172.16.0.38}"
NS_CIDR="${NS_CIDR:-24}"
NS_GW="${NS_GW:-172.16.0.1}"
NS_API_PORT="${NS_API_PORT:-52416}"
NS_LIBP2P_PORT="${NS_LIBP2P_PORT:-5680}"
NS_MACVLAN_IF="${NS_MACVLAN_IF:-macvlan-exo-r1}"
NS_HOST_IF="${NS_HOST_IF:-macvlan-host-r1}"
NS_BOOTSTRAP_HOST_IP="${NS_BOOTSTRAP_HOST_IP:-172.16.0.39}"
NS_BOOTSTRAP_HOST_CIDR="${NS_BOOTSTRAP_HOST_CIDR:-32}"
MASTER_OVERRIDE_MEMORY_MB="${MASTER_OVERRIDE_MEMORY_MB:-24000}"
REMOTE_OVERRIDE_MEMORY_MB="${REMOTE_OVERRIDE_MEMORY_MB:-12000}"
NS_OVERRIDE_MEMORY_MB="${NS_OVERRIDE_MEMORY_MB:-12000}"
NS_PIDFILE="/var/run/exo-worker-netns.pid"
NS_LOGFILE="/tmp/exo-worker-netns.log"

ACTION="${1:-status}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err() { echo -e "${RED}[ERR]${NC} $*"; }

ssh_master() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "bdeeley@${MASTER_IP}" "$@"
}

ssh_remote() {
  local ip="$1"
  shift
  # manage remotes through maxpower jump if needed
  ssh -o BatchMode=yes -o ConnectTimeout=8 "bdeeley@${MASTER_IP}" \
    "ssh -o BatchMode=yes -o ConnectTimeout=8 bdeeley@${ip} '$*'"
}

start_remotes() {
  while IFS=: read -r node_name node_ip node_port; do
    node_name="$(echo "$node_name" | xargs)"
    node_ip="$(echo "$node_ip" | xargs)"
    [[ -z "$node_ip" ]] && continue
    log_info "Starting remote ${node_name} (${node_ip})"
    ssh_remote "$node_ip" "sudo systemctl daemon-reload && sudo systemctl start exo.service" >/dev/null
  done <<< "$REMOTE_NODES"
}

stop_remotes() {
  while IFS=: read -r node_name node_ip node_port; do
    node_name="$(echo "$node_name" | xargs)"
    node_ip="$(echo "$node_ip" | xargs)"
    [[ -z "$node_ip" ]] && continue
    log_info "Stopping remote ${node_name} (${node_ip})"
    ssh_remote "$node_ip" "sudo systemctl stop exo.service || true" >/dev/null || true
  done <<< "$REMOTE_NODES"
}

apply_runtime_overrides() {
  log_info "Applying deterministic memory overrides (master=${MASTER_OVERRIDE_MEMORY_MB}MB, remote=${REMOTE_OVERRIDE_MEMORY_MB}MB, netns=${NS_OVERRIDE_MEMORY_MB}MB)"

  ssh_master "sudo mkdir -p /etc/systemd/system/exo.service.d && printf '%s\n' '[Service]' 'Environment=OVERRIDE_MEMORY_MB=${MASTER_OVERRIDE_MEMORY_MB}' | sudo tee /etc/systemd/system/exo.service.d/zzzz-cluster-memory.conf >/dev/null"

  while IFS=: read -r node_name node_ip node_port; do
    node_name="$(echo "$node_name" | xargs)"
    node_ip="$(echo "$node_ip" | xargs)"
    [[ -z "$node_ip" ]] && continue
    log_info "Setting remote memory override on ${node_name} (${node_ip})"
    ssh_remote "$node_ip" "sudo mkdir -p /etc/systemd/system/exo.service.d && printf \"%s\\n\" \"[Service]\" \"Environment=OVERRIDE_MEMORY_MB=${REMOTE_OVERRIDE_MEMORY_MB}\" | sudo tee /etc/systemd/system/exo.service.d/zzzz-cluster-memory.conf >/dev/null"
  done <<< "$REMOTE_NODES"

  ssh_master "sudo systemctl daemon-reload"
  while IFS=: read -r node_name node_ip node_port; do
    node_ip="$(echo "$node_ip" | xargs)"
    [[ -z "$node_ip" ]] && continue
    ssh_remote "$node_ip" "sudo systemctl daemon-reload" >/dev/null
  done <<< "$REMOTE_NODES"
}

setup_netns() {
  log_info "Setting up netns ${NS_NAME} with ${NS_IP}/${NS_CIDR} on ${NS_PARENT_IF}"

  ssh_master "sudo ip netns del ${NS_NAME} 2>/dev/null || true"
  ssh_master "sudo ip link del ${NS_MACVLAN_IF} 2>/dev/null || true"
  ssh_master "sudo ip link del ${NS_HOST_IF} 2>/dev/null || true"

  ssh_master "sudo ip netns add ${NS_NAME}"
  ssh_master "sudo ip link add ${NS_MACVLAN_IF} link ${NS_PARENT_IF} type macvlan mode bridge"
  ssh_master "sudo ip link add ${NS_HOST_IF} link ${NS_PARENT_IF} type macvlan mode bridge"
  ssh_master "sudo ip link set ${NS_MACVLAN_IF} netns ${NS_NAME}"
  ssh_master "sudo ip addr flush dev ${NS_HOST_IF} 2>/dev/null || true"
  ssh_master "sudo ip addr add ${NS_BOOTSTRAP_HOST_IP}/${NS_BOOTSTRAP_HOST_CIDR} dev ${NS_HOST_IF}"
  ssh_master "sudo ip link set ${NS_HOST_IF} up"
  ssh_master "sudo ip route replace ${NS_IP}/32 dev ${NS_HOST_IF}"
  ssh_master "sudo ip -n ${NS_NAME} link set lo up"
  ssh_master "sudo ip -n ${NS_NAME} addr add ${NS_IP}/${NS_CIDR} dev ${NS_MACVLAN_IF}"
  ssh_master "sudo ip -n ${NS_NAME} link set ${NS_MACVLAN_IF} up"
  ssh_master "sudo ip -n ${NS_NAME} route replace default via ${NS_GW} dev ${NS_MACVLAN_IF}"

  log_ok "Namespace configured"
}

teardown_netns() {
  log_info "Tearing down netns ${NS_NAME}"
  ssh_master "if [ -f ${NS_PIDFILE} ]; then pid=\$(cat ${NS_PIDFILE}); sudo kill -9 \"\$pid\" 2>/dev/null || true; sudo rm -f ${NS_PIDFILE}; fi"
  ssh_master "sudo ip netns del ${NS_NAME} 2>/dev/null || true"
  ssh_master "sudo ip link del ${NS_MACVLAN_IF} 2>/dev/null || true"
  ssh_master "sudo ip link del ${NS_HOST_IF} 2>/dev/null || true"
  ssh_master "sudo ip route del ${NS_IP}/32 dev ${NS_HOST_IF} 2>/dev/null || true"
  log_ok "Namespace removed"
}

start_master() {
  log_info "Starting master service"
  ssh_master "sudo systemctl daemon-reload && sudo systemctl start exo.service"
}

stop_master() {
  log_info "Stopping master services"
  ssh_master "sudo systemctl stop exo-worker.service exo.service || true"
}

start_netns_worker() {
  log_info "Starting netns worker process in ${NS_NAME}"

  local bootstrap_peers="/ip4/${NS_BOOTSTRAP_HOST_IP}/tcp/${MASTER_LIBP2P_PORT}"
  ssh_master "sudo systemctl stop exo-worker.service || true"
  # Clean stale host-namespace workers that can otherwise appear as phantom nodes.
  ssh_master "sudo fuser -k ${NS_API_PORT}/tcp >/dev/null 2>&1 || true"
  ssh_master "sudo fuser -k ${NS_LIBP2P_PORT}/tcp >/dev/null 2>&1 || true"
  ssh_master "sudo rm -f ${NS_PIDFILE}"

  ssh_master "sudo ip netns exec ${NS_NAME} bash -lc 'nohup env \
    XDG_CACHE_HOME=/home/bdeeley/.cache/exo-worker-netns \
    XDG_DATA_HOME=/home/bdeeley/.local/share \
    XDG_CONFIG_HOME=/home/bdeeley/.config/exo-worker-netns \
    OVERRIDE_MEMORY_MB=${NS_OVERRIDE_MEMORY_MB} \
    LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cuda_runtime/lib \
    CUDA_VISIBLE_DEVICES=0 \
    ${EXO_BIN} \
      --no-master-candidate \
      --api-port ${NS_API_PORT} \
      --libp2p-port ${NS_LIBP2P_PORT} \
      --bootstrap-peers ${bootstrap_peers} \
      > ${NS_LOGFILE} 2>&1 & echo \$! > /tmp/exo-worker-netns.pid.tmp'"

  ssh_master "sudo mv /tmp/exo-worker-netns.pid.tmp ${NS_PIDFILE}"
  log_ok "Netns worker started"
}

wait_for_topology() {
  local expected_nodes="$1"
  local timeout_s="$2"
  local deadline=$(( $(date +%s) + timeout_s ))

  while true; do
    local nodes
    nodes="$(ssh_master "curl -fsS http://localhost:${MASTER_API_PORT}/state | jq '.topology.nodes | length'" 2>/dev/null || echo 0)"
    log_info "Topology nodes=${nodes}/${expected_nodes}"
    if [[ "$nodes" -ge "$expected_nodes" ]]; then
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      return 1
    fi
    sleep 3
  done
}

show_status() {
  echo "=== Services on ${MASTER_IP} ==="
  ssh_master "echo -n 'master exo.service: '; systemctl is-active exo.service || true"
  ssh_master "echo -n 'legacy exo-worker.service: '; systemctl is-active exo-worker.service || true"

  echo "=== Namespace ==="
  ssh_master "sudo ip netns list | grep -E '^${NS_NAME}( |$)' || true"
  ssh_master "ip -4 addr show ${NS_HOST_IF} 2>/dev/null | sed -n 's/^.*inet /host-bootstrap-ip: /p' || true"
  ssh_master "if [ -f ${NS_PIDFILE} ]; then echo -n 'netns worker pid: '; cat ${NS_PIDFILE}; else echo 'netns worker pid: none'; fi"

  echo "=== API reachability ==="
  ssh_master "curl -fsS http://localhost:${MASTER_API_PORT}/node_id | jq -r '.' || true"
  ssh_master "curl -fsS http://${NS_IP}:${NS_API_PORT}/node_id | jq -r '.' || true"

  echo "=== Topology snapshot ==="
  ssh_master "curl -fsS http://localhost:${MASTER_API_PORT}/state | jq '{nodes:.topology.nodes,connections:.topology.connections}' || true"
}

run_gate() {
  local expected_nodes="${2:-3}"
  "${SCRIPT_DIR}/cluster-success-gate.sh" \
    --api "http://${MASTER_IP}:${MASTER_API_PORT}" \
    --model "${1}" \
    --min-nodes "${expected_nodes}" \
    --expected-nodes "${expected_nodes}" \
    --timeout-seconds 90
}

diagnose_ring() {
  log_info "Collecting ring diagnostics from master state"
  local state_json
  state_json="$(ssh_master "curl -fsS http://localhost:${MASTER_API_PORT}/state")"

  echo "=== Runner Summary ==="
  echo "$state_json" | jq '{
    instances:(.instances|length),
    runners:(.runners|length),
    ready:([.runners[] | select(has("RunnerReady"))] | length),
    failed:([.runners[] | select(has("RunnerFailed"))] | length),
    connecting:([.runners[] | select(has("RunnerConnecting"))] | length),
    idle:([.runners[] | select(has("RunnerIdle"))] | length)
  }'

  echo "=== Instance / Rank / Node Mapping ==="
  echo "$state_json" | jq -r '
    . as $root
    | .instances
    | to_entries[]?
    | . as $inst
    | $inst.value.MlxRingInstance.shardAssignments as $sa
    | ($sa.nodeToRunner | to_entries[]?) as $nr
    | ($sa.runnerToShard[$nr.value].PipelineShardMetadata.deviceRank) as $rank
    | ($sa.runnerToShard[$nr.value].PipelineShardMetadata.worldSize) as $world
    | (($root.runners[$nr.value] // {}) | keys[0] // "Missing") as $status
    | (($root.runners[$nr.value].RunnerFailed.errorMessage) // "") as $err
    | "instance=\($inst.value.MlxRingInstance.instanceId) rank=\($rank)/\($world) node=\($nr.key) runner=\($nr.value) status=\($status) error=\($err)"
  '

  echo "=== hostsByNode (bind candidate is index 0) ==="
  echo "$state_json" | jq -r '
    .instances
    | to_entries[]?
    | .value.MlxRingInstance.hostsByNode
    | to_entries[]?
    | "node=\(.key) hosts=\(.value|map("\(.ip):\(.port)")|join(","))"
  '

  echo "=== Focus: bind/connect ring failures ==="
  echo "$state_json" | jq -r '
    .runners
    | to_entries[]?
    | select(.value.RunnerFailed)
    | .value.RunnerFailed.errorMessage
  ' | sed '/^$/d' || true
}

start_all() {
  log_info "Starting remotes + master + distinct-IP local rank"
  stop_all || true
  apply_runtime_overrides
  start_remotes
  sleep 8
  start_master
  sleep 5
  setup_netns
  start_netns_worker
  sleep 12

  if wait_for_topology 3 90; then
    log_ok "Distinct-IP architecture is up"
  else
    log_warn "Topology did not converge to expected nodes in time"
    return 1
  fi
}

stop_all() {
  log_info "Stopping distinct-IP cluster run"
  teardown_netns || true
  stop_master || true
  stop_remotes || true
}

case "$ACTION" in
  setup-netns)
    setup_netns
    ;;
  teardown-netns)
    teardown_netns
    ;;
  start)
    start_all
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all || true
    sleep 2
    start_all
    ;;
  status)
    show_status
    ;;
  gate)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 gate <model-id> [expected-nodes]"
      exit 2
    fi
    run_gate "$2" "${3:-3}"
    ;;
  diagnose-ring)
    diagnose_ring
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|setup-netns|teardown-netns|gate <model-id> [expected-nodes]|diagnose-ring}"
    exit 1
    ;;
esac
