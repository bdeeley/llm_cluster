# EXO Cluster Restart Session - June 20 2026, 14:05

## ACTION TAKEN
1. **Services Disabled** (12:29:22-12:29:23):
   - ollama.service (was using 5.4GB memory peak, 4.9GB active VRAM)
   - ollama-nothink-proxy.service
   - exo-worker.service

2. **Services Re-Enabled & Restarted** (14:05-14:08):
   - Created missing `/home/bdeeley/exo/dashboard/dist` directory
   - Re-enabled exo.service and exo-worker.service
   - Started master (14:07:09), then worker (14:08:43)

## CURRENT STATUS ✅

### Services Running
| Service | Status | PID | CPU | Mem | Start Time |
|---------|--------|-----|-----|-----|-----------|
| exo.service | active (running) | 850614 | 8.7% | 154MB | 14:07:09 |
| exo-worker.service | active (running) | 852575 | 19.0% | 153MB | 14:08:43 |

### Cluster State
- **Master Node**: 12D3KooWBBZTw6scHnfL4HwuwUh8YRHuJBaRFHEXo3zE7qMcoedS
- **Plan Cycles**: Running (visible in logs)
- **Runners**: 0 local, 0 global (no instances deployed yet)
- **GPU VRAM**: No exo/ollama processes on GPUs (display only: 1.2GB total)

### Centralized Logging
- Master logs: `/tmp/exo-cluster-logs/master.log` ✅
- Worker logs: `/tmp/exo-cluster-logs/worker.log` ✅
- Both using wrapper script: `/BIGMIRROR/exo-wrapper-simple.sh`
- Health check: `/BIGMIRROR/exo-cluster-health-check.sh`

## NEXT STEPS
1. Verify remote node (theplague) is running
2. Check cluster topology convergence
3. Deploy model instance to verify full stack

## CRITICAL: MAINTAIN STRICT LOGGING COMPLIANCE
All future restarts must:
- Use centralized logging in `/tmp/exo-cluster-logs/`
- Include health check (`ExecStartPre`) in service files
- Capture all stdout/stderr to journalctl
- Monitor for auth errors (HF_TOKEN issues are silent unless logged)
