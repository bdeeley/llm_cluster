#!/bin/bash
set -euo pipefail

# Deterministic cluster gate runner.
# Usage:
#   ./cluster-success-gate.sh \
#     --api http://172.16.0.28:52415 \
#     --model mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit \
#     --min-nodes 2 \
#     --expected-nodes 2 \
#     --timeout-seconds 120

API_URL="http://172.16.0.28:52415"
MODEL_ID=""
MIN_NODES=2
EXPECTED_NODES=2
TIMEOUT_SECONDS=120
POLL_SECONDS=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api) API_URL="$2"; shift 2 ;;
    --model) MODEL_ID="$2"; shift 2 ;;
    --min-nodes) MIN_NODES="$2"; shift 2 ;;
    --expected-nodes) EXPECTED_NODES="$2"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$MODEL_ID" ]]; then
  echo "ERROR: --model is required"
  exit 2
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1"
    exit 2
  }
}

need_cmd curl
need_cmd jq

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))

echo "Gate B: topology integrity"
while true; do
  state_json="$(curl -fsS "${API_URL}/state")"
  node_count="$(echo "$state_json" | jq '.topology.nodes | length')"
  conn_count="$(echo "$state_json" | jq '.topology.connections | length')"

  echo "  nodes=${node_count} connections=${conn_count}"

  if [[ "$node_count" -eq "$EXPECTED_NODES" ]]; then
    break
  fi

  if [[ $(date +%s) -ge $deadline ]]; then
    echo "FAIL: topology gate timed out"
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

echo "Gate C: placement integrity"
pre_state_json="$(curl -fsS "${API_URL}/state")"
pre_task_ids_json="$(echo "$pre_state_json" | jq -c '.tasks // {} | keys')"
pre_instance_ids_json="$(echo "$pre_state_json" | jq -c '.instances // {} | keys')"

existing_instance_ids="$(echo "$pre_state_json" | jq -r '.instances | keys[]?')"
if [[ -n "$existing_instance_ids" ]]; then
  echo "  clearing stale instances before placement"
  while IFS= read -r iid; do
    [[ -z "$iid" ]] && continue
    curl -fsS -X DELETE "${API_URL}/instance/${iid}" >/dev/null || true
  done <<< "$existing_instance_ids"

  clear_deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
  while true; do
    remaining="$(curl -fsS "${API_URL}/state" | jq '.instances | length')"
    if [[ "$remaining" -eq 0 ]]; then
      break
    fi
    if [[ $(date +%s) -ge $clear_deadline ]]; then
      echo "FAIL: stale instance cleanup timed out"
      exit 1
    fi
    sleep "$POLL_SECONDS"
  done
fi

place_payload="$(jq -cn --arg m "$MODEL_ID" --argjson n "$MIN_NODES" '{model_id:$m,min_nodes:$n}')"
place_resp="$(curl -fsS -X POST "${API_URL}/place_instance" -H 'Content-Type: application/json' -d "$place_payload")"
echo "  placement accepted: $(echo "$place_resp" | jq -r '.command_id // "n/a"')"

target_instance_id=""
placement_deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while true; do
  state_json="$(curl -fsS "${API_URL}/state")"
  target_instance_id="$(echo "$state_json" | jq -r --argjson pre "$pre_task_ids_json" '
    [(.tasks // {})
      | to_entries[]?
      | . as $e
      | select(($pre | index($e.key)) | not)
      | $e.value.CreateRunner?
      | select(.instanceId != null)
      | .instanceId
    ][0] // empty
  ')"
  if [[ -z "$target_instance_id" ]]; then
    target_instance_id="$(echo "$state_json" | jq -r --argjson prei "$pre_instance_ids_json" '
      [(.instances // {})
        | to_entries[]?
        | .key
        | select(($prei | index(.)) | not)
      ][0] // empty
    ')"
  fi
  if [[ -n "$target_instance_id" ]]; then
    break
  fi
  if [[ $(date +%s) -ge $placement_deadline ]]; then
    echo "FAIL: placement gate timed out waiting for new instance"
    exit 1
  fi
  sleep "$POLL_SECONDS"
done
echo "  target instance: ${target_instance_id}"

echo "Gate D: runner integrity"
runner_deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while true; do
  state_json="$(curl -fsS "${API_URL}/state")"
  runner_statuses_json="$(echo "$state_json" | jq -c --arg iid "$target_instance_id" '
    [(.tasks // {})
      | to_entries[]?
      | .value.CreateRunner?
      | select(.instanceId == $iid)
      | .boundInstance.boundRunnerId
    ]
    | unique
    | map({
        id: .,
        status: ((. as $rid | ($state.runners[$rid] // {}) | keys[0]) // "Missing"),
        error: ((. as $rid | ($state.runners[$rid] // {}) | .RunnerFailed.errorMessage) // null)
      })
    ' --argjson state "$state_json")"

  runner_count="$(echo "$runner_statuses_json" | jq 'length')"
  failed_count="$(echo "$runner_statuses_json" | jq '[.[] | select(.status=="RunnerFailed")] | length')"
  readyish_count="$(echo "$runner_statuses_json" | jq '[.[] | select(.status=="RunnerIdle" or .status=="RunnerReady" or .status=="RunnerWarmingUp" or .status=="RunnerLoading" or .status=="RunnerConnected")] | length')"

  echo "  instance=${target_instance_id} runners=${runner_count} failed=${failed_count} readyish=${readyish_count}"

  if [[ "$failed_count" -gt 0 ]]; then
    echo "  failed runner details:"
    echo "$runner_statuses_json" | jq -r '.[] | select(.status=="RunnerFailed") | "    \(.id): \(.error // "unknown")"'
    echo "FAIL: at least one runner is RunnerFailed"
    exit 1
  elif [[ "$runner_count" -lt "$MIN_NODES" ]]; then
    :
  elif [[ "$runner_count" -ge "$MIN_NODES" && "$readyish_count" -ge "$MIN_NODES" ]]; then
    echo "PASS: placement and runner gates passed"
    break
  fi

  if [[ $(date +%s) -ge $runner_deadline ]]; then
    echo "FAIL: runner gate timed out"
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

echo "Gate E: bounded inference check"
infer_payload='{"model":"'"$MODEL_ID"'","messages":[{"role":"user","content":"Say ok."}],"max_tokens":16}'
if curl -fsS -m 25 -X POST "${API_URL}/v1/chat/completions" -H 'Content-Type: application/json' -d "$infer_payload" >/tmp/cluster_success_infer.json 2>/dev/null; then
  content="$(jq -r '.choices[0].message.content // empty' /tmp/cluster_success_infer.json)"
  if [[ -n "$content" ]]; then
    echo "PASS: inference gate passed"
    echo "SUCCESS: all gates passed"
    exit 0
  fi
fi

echo "FAIL: inference gate failed"
exit 1
