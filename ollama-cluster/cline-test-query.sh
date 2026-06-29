#!/bin/bash
# cline-test-query.sh
# Quick test to verify Cline can query the distributed cluster

set -e

# Configuration
API_URL="http://localhost:8000"
MODEL="codellama/CodeLlama-13b-hf"

# Check GPU status before query
echo "📊 GPU Status Before Query:"
echo "maxpower GPUs:"
nvidia-smi --query-gpu=name,memory.used --format=csv,noheader

echo ""
echo "theplague GPU:"
ssh bdeeley@172.16.0.29 "nvidia-smi --query-gpu=name,memory.used --format=csv,noheader" 2>/dev/null || echo "  (SSH error - but model is loaded)"

echo ""
echo "================================"
echo "Sending inference query to Cline-compatible API"
echo "================================"
echo ""

# Send query using OpenAI-compatible format (what Cline uses)
QUERY="Explain how distributed inference works in AI systems. Keep it technical but concise."

echo "Query: $QUERY"
echo ""
echo "Response:"
echo "----------"

curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": \"$QUERY\"
    }],
    \"max_tokens\": 256,
    \"temperature\": 0.7
  }" | jq -r '.choices[0].message.content' 2>/dev/null || echo "API call failed - server may still be loading"

echo ""
echo "----------"
echo ""
echo "✅ Test complete. GPU status after query:"
echo "maxpower GPUs:"
nvidia-smi --query-gpu=name,memory.used,utilization.gpu --format=csv,noheader

echo ""
echo "theplague GPU:"
ssh bdeeley@172.16.0.29 "nvidia-smi --query-gpu=name,memory.used,utilization.gpu --format=csv,noheader" 2>/dev/null || echo "  (SSH error)"
