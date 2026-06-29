#!/bin/bash
# Test both inference servers

THEPLAGUE_HOST="172.16.0.62"

echo "=========================================="
echo "Testing CodeLlama-34B Cluster"
echo "=========================================="

# Test maxpower
echo ""
echo "1️⃣  Testing maxpower..."
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "Say hello briefly"}],
    "max_tokens": 30
  }' | python3 -c "import sys, json; r=json.load(sys.stdin); print('✓ Response:', r.get('choices', [{}])[0].get('message', {}).get('content', 'ERROR'))" 2>&1 || echo "❌ maxpower failed"

# Test theplague
echo ""
echo "2️⃣  Testing theplague..."
ssh "$THEPLAGUE_USER@$THEPLAGUE_HOST" bash -s << 'TEST_SCRIPT'
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "Say hello briefly"}],
    "max_tokens": 30
  }' | python3 -c "import sys, json; r=json.load(sys.stdin); print('✓ Response:', r.get('choices', [{}])[0].get('message', {}).get('content', 'ERROR'))" 2>&1 || echo "❌ theplague failed"
TEST_SCRIPT

echo ""
echo "=========================================="
echo "✅ Test Complete"
echo "=========================================="
