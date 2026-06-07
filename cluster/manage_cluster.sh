#!/usr/bin/env bash
# Compatibility wrapper for legacy automation entrypoint.
# Canonical operations now live in:
# - ../cluster-control.sh
# - ../cluster-diagnose.sh
# - ./cleanup-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMAND="${1:-start}"

case "$COMMAND" in
    start)
        echo "[manage_cluster] Delegating start to cluster-control.sh"
        exec "$ROOT_DIR/cluster-control.sh" start
        ;;
    stop)
        echo "[manage_cluster] Delegating stop to cluster-control.sh"
        exec "$ROOT_DIR/cluster-control.sh" stop
        ;;
    status)
        echo "[manage_cluster] Delegating status to cluster-control.sh"
        exec "$ROOT_DIR/cluster-control.sh" status
        ;;
    logs)
        echo "[manage_cluster] Delegating logs to cluster-control.sh"
        exec "$ROOT_DIR/cluster-control.sh" logs
        ;;
    diagnose)
        echo "[manage_cluster] Delegating diagnostics to cluster-diagnose.sh"
        exec "$ROOT_DIR/cluster-diagnose.sh" all
        ;;
    cleanup)
        echo "[manage_cluster] Running cleanup-all.sh"
        exec "$SCRIPT_DIR/cleanup-all.sh"
        ;;
    help|-h|--help)
        cat <<'EOF'
Usage: cluster/manage_cluster.sh <command>

Commands:
    start      Start cluster via cluster-control.sh
    stop       Stop cluster via cluster-control.sh
    status     Show cluster status via cluster-control.sh
    logs       Tail logs via cluster-control.sh
    diagnose   Run cluster-diagnose.sh all
    cleanup    Run cluster/cleanup-all.sh

Path forward:
    1) Keep using cluster-control.sh + cluster-diagnose.sh as source of truth.
    2) For compute distribution testing, use supportsTensor=true models and
         explicit sharding=Tensor placement after 10 Gb network uplift.
EOF
        ;;
    *)
        echo "Unknown command: $COMMAND"
        echo "Run: $0 --help"
        exit 1
        ;;
esac
