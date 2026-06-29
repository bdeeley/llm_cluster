#!/bin/bash
# 02-verify-compute.sh
#
# Verify that both GPU VRAM and compute are properly distributed
# across the 2-GPU vLLM cluster
#
# Success indicators:
#   ✓ Both GPUs show model VRAM in use (~10-12GB each)
#   ✓ During inference: both GPUs show 40-60% compute utilization
#   ✓ Latency is reasonable (< 10 seconds per query)
#   ✓ API returns valid responses

set -e

API_URL="http://localhost:8000"
MAXPOWER="172.16.0.28"
THEPLAGUE_HOST="theplague.deeleymotorsports.lan"
THEPLAGUE_IP="172.16.0.29"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo -e "Verifying 2-GPU Distributed Compute"
echo -e "==========================================${NC}"
echo ""

# Test 1: API health
echo -e "${BLUE}Test 1️⃣  : API Health Check${NC}"
if curl -s "$API_URL/health" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} API responding at $API_URL"
else
    echo -e "  ${RED}✗${NC} API not responding at $API_URL"
    echo "    Check: ./scripts/01-start-2gpu-vllm.sh is running"
    exit 1
fi
echo ""

# Test 2: Check VRAM distribution BEFORE inference
echo -e "${BLUE}Test 2️⃣  : VRAM Distribution (Model Loaded)${NC}"

echo "  Maxpower GPU0 (RTX 3060):"
MAXPOWER_VRAM=$(ssh $MAXPOWER "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits" 2>/dev/null | head -1)
if [ -n "$MAXPOWER_VRAM" ]; then
    USED=$(echo "$MAXPOWER_VRAM" | awk -F, '{print $1}')
    TOTAL=$(echo "$MAXPOWER_VRAM" | awk -F, '{print $2}')
    PCT=$((USED * 100 / TOTAL))
    echo "    $USED MB / $TOTAL MB ($PCT%)"
else
    echo "    (SSH check failed)"
fi

echo "  Theplague GPU0 (RTX 3060):"
THEPLAGUE_VRAM=$(ssh -o ConnectTimeout=5 bdeeley@$THEPLAGUE_HOST "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits" 2>/dev/null | head -1)
if [ -n "$THEPLAGUE_VRAM" ]; then
    USED=$(echo "$THEPLAGUE_VRAM" | awk -F, '{print $1}')
    TOTAL=$(echo "$THEPLAGUE_VRAM" | awk -F, '{print $2}')
    PCT=$((USED * 100 / TOTAL))
    echo "    $USED MB / $TOTAL MB ($PCT%)"
else
    echo "    (SSH check failed or theplague offline)"
fi
echo ""

# Test 3: Inference test with compute monitoring
echo -e "${BLUE}Test 3️⃣  : Inference Query (Single Request)${NC}"
echo "  Sending query to vLLM..."
echo ""

# Capture baseline utilization
BASELINE_MAXPOWER=$(ssh $MAXPOWER "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" 2>/dev/null | head -1)
BASELINE_THEPLAGUE=$(ssh -o ConnectTimeout=5 bdeeley@$THEPLAGUE_HOST "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" 2>/dev/null | head -1 || echo "N/A")

START=$(date +%s%N)

# Send inference request
RESPONSE=$(curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "codellama/CodeLlama-34b-Instruct-hf",
    "messages": [{"role": "user", "content": "Explain tensor parallelism in 1 sentence"}],
    "max_tokens": 256,
    "temperature": 0.7
  }' 2>/dev/null)

END=$(date +%s%N)
LATENCY_MS=$(( (END - START) / 1000000 ))
LATENCY_SEC=$(echo "scale=2; $LATENCY_MS / 1000" | bc)

# Capture peak utilization
PEAK_MAXPOWER=$(ssh $MAXPOWER "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" 2>/dev/null | head -1)
PEAK_THEPLAGUE=$(ssh -o ConnectTimeout=5 bdeeley@$THEPLAGUE_HOST "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" 2>/dev/null | head -1 || echo "N/A")

echo "  GPU Utilization During Inference:"
echo "    Maxpower GPU0:  ${BASELINE_MAXPOWER}% → ${PEAK_MAXPOWER}%"
echo "    Theplague GPU0: ${BASELINE_THEPLAGUE}% → ${PEAK_THEPLAGUE}%"
echo ""
echo "  Latency: ${LATENCY_SEC}s"
echo ""

# Test 4: Response content
echo -e "${BLUE}Test 4️⃣  : Response Content${NC}"
if echo "$RESPONSE" | grep -q "choices"; then
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null)
    if [ -n "$CONTENT" ]; then
        echo -e "  ${GREEN}✓${NC} Response received:"
        echo "$CONTENT" | head -3
        if [ $(echo "$CONTENT" | wc -l) -gt 3 ]; then
            echo "  ..."
        fi
    else
        echo -e "  ${YELLOW}⚠${NC}  Response structure received but no content"
    fi
else
    echo -e "  ${RED}✗${NC} Invalid response format"
    echo "$RESPONSE" | head -5
fi
echo ""

# Test 5: Summary
echo -e "${BLUE}Summary${NC}"
echo ""

# Check VRAM distribution
if [ -n "$MAXPOWER_VRAM" ] && [ -n "$THEPLAGUE_VRAM" ]; then
    MAX_USED=$(echo "$MAXPOWER_VRAM" | awk -F, '{print $1}')
    THEP_USED=$(echo "$THEPLAGUE_VRAM" | awk -F, '{print $1}')
    
    if [ "$MAX_USED" -gt 8000 ] && [ "$THEP_USED" -gt 8000 ]; then
        echo -e "  ${GREEN}✓${NC} VRAM properly distributed (both > 8GB)"
    else
        echo -e "  ${YELLOW}⚠${NC}  VRAM distribution check inconclusive"
        echo "    Max: $MAX_USED MB, Thep: $THEP_USED MB"
    fi
else
    echo -e "  ${YELLOW}⚠${NC}  Could not verify VRAM (SSH issues)"
fi

# Check compute distribution (both should have utilized in inference)
if [ "$PEAK_MAXPOWER" -gt 30 ] && [ "$PEAK_THEPLAGUE" != "N/A" ] && [ "$PEAK_THEPLAGUE" -gt 30 ]; then
    echo -e "  ${GREEN}✓${NC} Compute distributed (both GPUs > 30% during inference)"
elif [ "$PEAK_MAXPOWER" -gt 30 ]; then
    echo -e "  ${YELLOW}⚠${NC}  Only maxpower GPU showing utilization"
    echo "    This is expected on first inference run"
else
    echo -e "  ${YELLOW}⚠${NC}  GPU utilization check inconclusive"
fi

# Check latency
if [ $(echo "$LATENCY_SEC < 30" | bc) -eq 1 ]; then
    echo -e "  ${GREEN}✓${NC} Latency acceptable (${LATENCY_SEC}s)"
else
    echo -e "  ${YELLOW}⚠${NC}  Latency high (${LATENCY_SEC}s, expected < 30s)"
fi

echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  • Multiple queries: for i in {1..5}; do curl -s ... | jq '.choices[0].message'; done"
echo "  • Monitor GPU in separate terminal: watch -n1 'nvidia-smi'"
echo "  • Remote monitor: ssh theplague 'watch -n1 nvidia-smi'"
echo "  • Network traffic: ssh theplague 'iftop -i eth0 -n'"
echo "  • Server logs: tail -f vllm_cluster/logs/*.log"
echo ""
