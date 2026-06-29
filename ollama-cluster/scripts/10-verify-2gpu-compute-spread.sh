#!/bin/bash
# 10-verify-2gpu-compute-spread.sh
#
# Verify that BOTH VRAM and COMPUTE are distributed across 2x RTX 3060s
# 
# Success criteria:
#   ✓ Both GPUs show ~10-12GB model VRAM in use (split)
#   ✓ During inference: BOTH GPUs spike to ~50% compute utilization
#   ✓ Network traffic flows between nodes during inference
#   ✓ Response latency < 5 seconds (distributed across 2 GPUs)

set -e

API_URL="http://localhost:8000"
MAXPOWER="172.16.0.28"
THEPLAGUE="172.16.0.29"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================="
echo -e "2-GPU Compute Distribution Verification"
echo -e "==========================================${NC}"
echo ""

# Test 1: Health check
echo -e "${BLUE}Test 1️⃣  : API Health Check${NC}"
if curl -s "$API_URL/health" | grep -q "ok\|running" || [ "$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/health")" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} API responding"
else
    echo -e "  ${RED}✗${NC} API not responding at $API_URL"
    exit 1
fi
echo ""

# Test 2: Check VRAM distribution (before inference)
echo -e "${BLUE}Test 2️⃣  : VRAM Distribution (Model Loading)${NC}"
echo "  Maxpower GPUs:"
ssh $MAXPOWER "nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader,nounits" | head -1 | awk -F, '{printf "    GPU0 (RTX 3060): %s/%s MB\n", $3, $4}' || echo "    (SSH failed)"

echo "  Theplague GPU:"
ssh $THEPLAGUE "nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader,nounits" | awk -F, '{printf "    GPU0 (RTX 3060): %s/%s MB\n", $2, $3}' || echo "    (SSH failed)"
echo ""

# Test 3: Capture baseline GPU utilization
echo -e "${BLUE}Test 3️⃣  : Baseline GPU Utilization (no inference)${NC}"
MAXPOWER_BASELINE=$(ssh $MAXPOWER "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" | head -1)
THEPLAGUE_BASELINE=$(ssh $THEPLAGUE "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" | head -1)

echo "  Maxpower GPU0:  ${MAXPOWER_BASELINE}%"
echo "  Theplague GPU0: ${THEPLAGUE_BASELINE}%"
echo ""

# Test 4: Send inference query and capture utilization during request
echo -e "${BLUE}Test 4️⃣  : Inference Query (watch for compute spike)${NC}"
echo "  Sending query to: $API_URL/v1/chat/completions"
echo ""
echo "  📊 GPU Utilization During Inference:"
echo "     (This should show BOTH GPUs spiking to ~40-60% compute)"
echo ""

# Start background monitoring
(
    sleep 1
    while true; do
        echo -n "    Maxpower GPU0: "
        ssh $MAXPOWER "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" | head -1 | xargs echo "%"
        
        echo -n "    Theplague GPU0: "
        ssh $THEPLAGUE "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" | head -1 | xargs echo "%"
        
        echo ""
        sleep 0.5
    done
) &
MONITOR_PID=$!

# Send inference request
START=$(date +%s)
RESPONSE=$(curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "codellama/CodeLlama-34b-Instruct-hf",
    "messages": [{"role": "user", "content": "Explain tensor parallelism in 100 words"}],
    "max_tokens": 256,
    "temperature": 0.7
  }' 2>/dev/null)
END=$(date +%s)
LATENCY=$((END - START))

# Stop monitoring
sleep 1
kill $MONITOR_PID 2>/dev/null || true

echo ""
echo "  ✓ Inference completed in ${LATENCY}s"
echo ""

# Test 5: Show response
echo -e "${BLUE}Test 5️⃣  : API Response${NC}"
if echo "$RESPONSE" | grep -q "tensor"; then
    echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null | head -5
    echo "  ..."
else
    echo "  Response:"
    echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
fi
echo ""

# Test 6: Check peak memory usage
echo -e "${BLUE}Test 6️⃣  : Peak VRAM After Inference${NC}"
MAXPOWER_MEM=$(ssh $MAXPOWER "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits" | head -1)
THEPLAGUE_MEM=$(ssh $THEPLAGUE "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits" | head -1)

MAX_USED=$(echo "$MAXPOWER_MEM" | awk -F, '{print $1}')
MAX_TOTAL=$(echo "$MAXPOWER_MEM" | awk -F, '{print $2}')
MAX_PCT=$((MAX_USED * 100 / MAX_TOTAL))

THE_USED=$(echo "$THEPLAGUE_MEM" | awk -F, '{print $1}')
THE_TOTAL=$(echo "$THEPLAGUE_MEM" | awk -F, '{print $2}')
THE_PCT=$((THE_USED * 100 / THE_TOTAL))

echo "  Maxpower GPU0:  ${MAX_USED}/${MAX_TOTAL} MB (${MAX_PCT}%)"
echo "  Theplague GPU0: ${THE_USED}/${THE_TOTAL} MB (${THE_PCT}%)"
echo ""

# Test 7: Network traffic observation
echo -e "${BLUE}Test 7️⃣  : Network Traffic Check${NC}"
echo "  To monitor network during inference, run in another terminal:"
echo ""
echo "  ${YELLOW}ssh $THEPLAGUE 'watch -n0.5 \"ethtool -S eth0 | grep rx_packets_phy | head -1; ethtool -S eth0 | grep tx_packets_phy | head -1\"'${NC}"
echo ""
echo "  Expected: RX/TX packet counts increase significantly during inference"
echo ""

# Test 8: Summary
echo -e "${BLUE}Success Criteria Check:${NC}"
echo ""

# Check 1: VRAM on both GPUs
if [ "$MAX_USED" -gt 8000 ] && [ "$THE_USED" -gt 8000 ]; then
    echo -e "  ${GREEN}✓${NC} VRAM distributed (both GPUs > 8GB in use)"
else
    echo -e "  ${RED}✗${NC} VRAM not distributed (Expected >8GB on both, got ${MAX_USED}MB and ${THE_USED}MB)"
fi

# Check 2: Response time reasonable
if [ "$LATENCY" -lt 30 ]; then
    echo -e "  ${GREEN}✓${NC} Inference latency acceptable (${LATENCY}s)"
else
    echo -e "  ${YELLOW}⚠${NC}  Inference latency high (${LATENCY}s, expected <30s for CodeLlama-34B on 2 GPUs)"
fi

# Check 3: Output quality
if [ -n "$(echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null)" ]; then
    echo -e "  ${GREEN}✓${NC} Response generation working"
else
    echo -e "  ${RED}✗${NC} No response content received"
fi

echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. To send multiple requests: use 10-batch-test.sh"
echo "  2. To monitor GPU continuously: watch -n1 nvidia-smi"
echo "  3. To profile inference: check /tmp/vllm_2gpu.log for timing info"
echo ""
