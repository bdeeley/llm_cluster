#!/bin/bash
echo "=== Cluster Status ==="
curl -s http://localhost:52415/state | jq '.nodeIdentities | length' && echo "nodes connected"

echo ""
echo "=== Sending placement request ==="
curl -s http://localhost:52415/api/v1/inferences_group \
  -H "Content-Type: application/json" \
  -d '{
    "model": {
      "modelId": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
      "modelSize": 4794980352
    },
    "requestedWorkers": 4
  }' | jq -r '.command_id' > /tmp/cmd_id.txt

CMD_ID=$(cat /tmp/cmd_id.txt)
echo "Command ID: $CMD_ID"

echo ""
echo "=== Monitoring runners (15 seconds) ==="
for i in {1..15}; do
  RUNNERS=$(curl -s http://localhost:52415/state | jq '.inferencesGroup.runners | length' 2>/dev/null || echo 0)
  READY=$(curl -s http://localhost:52415/state | jq "[.inferencesGroup.runners[] | select(.status == \"RunnerReady\")] | length" 2>/dev/null || echo 0)
  echo "  [$i/15] Runners: $RUNNERS, Ready: $READY"
  sleep 1
done

echo ""
echo "=== Final State ==="
curl -s http://localhost:52415/state | jq '{
  runners: (.inferencesGroup.runners | length),
  ready: ([.inferencesGroup.runners[] | select(.status == "RunnerReady")] | length),
  failed: ([.inferencesGroup.runners[] | select(.status == "RunnerFailed")] | length)
}' 2>/dev/null || echo "API error"
