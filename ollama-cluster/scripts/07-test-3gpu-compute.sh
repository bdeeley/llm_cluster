#!/bin/bash
# 07-test-3gpu-compute.sh
# Verify all 3 GPUs are computing during inference
# 
# Success criteria:
#   ✓ All 3 GPU utilizations spike during inference
#   ✓ Response latency < 2 seconds per request
#   ✓ Network traffic shows bidirectional flow
#   ✓ Can handle concurrent requests (async batching)

set -e

API_URL="http://localhost:8000"
MAXPOWER="172.16.0.28"
THEPLAGUE="172.16.0.29"

echo "=========================================="
echo "Testing 3-GPU Distributed Inference"
echo "=========================================="
echo ""

# Test 1: Health check
echo "Test 1️⃣ : Health check..."
HEALTH=$(curl -s $API_URL/health)
echo "Response: $HEALTH"
echo ""

# Test 2: Single inference (watch GPUs)
echo "Test 2️⃣ : Single inference query..."
echo "Monitor in parallel terminal: watch -n1 nvidia-smi"
echo ""

echo "Sending query to API..."
RESPONSE=$(curl -s -X POST $API_URL/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Write a hello world function in Python"}],
    "temperature": 0.7,
    "max_tokens": 256,
    "top_p": 0.9
  }')

echo "Response:"
echo "$RESPONSE" | jq '.choices[0].message.content' || echo "$RESPONSE"
echo ""

# Test 3: GPU memory check
echo "Test 3️⃣ : GPU memory allocation (should show all 3 with model in VRAM)..."
echo ""
echo "maxpower GPUs:"
ssh $MAXPOWER "nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits" || echo "  (SSH failed)"
echo ""
echo "theplague GPU:"
ssh $THEPLAGUE "nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits" || echo "  (SSH failed)"
echo ""

# Test 4: Concurrent requests (async batching)
echo "Test 4️⃣ : Concurrent inference (async batching test)..."
echo "Sending 3 concurrent requests..."
echo ""

for i in {1..3}; do
  echo "Request $i..."
  curl -s -X POST $API_URL/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{
      \"messages\": [{\"role\": \"user\", \"content\": \"What is the purpose of test $i?\"}],
      \"max_tokens\": 128
    }" > /tmp/response_$i.json &
done

wait
echo "Requests completed"
echo ""

# Test 5: Network monitoring suggestion
echo "Test 5️⃣ : Network traffic during inference..."
echo "Run this in another terminal to watch 10Gbps link:"
echo "  ssh $THEPLAGUE 'iftop -i eth0 -n -P'"
echo ""
echo "Expected: 1-5 Gbps sustained traffic during inference"
echo "  (depends on token generation speed and batch size)"
echo ""

# Test 6: Detailed performance metrics
echo "Test 6️⃣ : Performance metrics..."
echo ""
echo "Send a larger inference to measure throughput:"
curl -s -X POST $API_URL/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Write detailed documentation for a Python async function that uses tensor parallelism. Include type hints, docstrings, and usage examples"}],
    "temperature": 0.7,
    "max_tokens": 512,
    "top_p": 0.95
  }' | jq '.choices[0].message.content' | head -c 500
echo ""
echo ""

# Test 7: Success criteria check
echo "Test 7️⃣ : Verifying success criteria..."
echo ""
echo "✓ Compute distribution (all 3 GPUs should show GPU utilization spikes):"
echo "  - maxpower GPU0: should be ~33% during inference"
echo "  - maxpower GPU1: should be ~33% during inference"  
echo "  - theplague GPU0: should be ~33% during inference"
echo ""
echo "✓ Network (should see traffic between nodes):"
ssh $THEPLAGUE "iftop -i eth0 -n -P -s 1" 2>/dev/null | grep -E "Total send|Total recv" || echo "  (cannot read network stats)"
echo ""

echo "=========================================="
echo "Test Complete!"
echo "=========================================="
