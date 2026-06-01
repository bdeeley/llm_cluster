#!/usr/bin/env python3
"""
Ollama Cluster Proxy — port 11435
Routes requests to local (:11434) or remote nodes based on model-name prefix.

Model naming:
  gpt-oss-cline:20b           → local (unchanged, all existing Cline variants)
  node-a/qwen2.5-coder:32b    → llm-node-a:11434
  node-b/mistral:7b           → llm-node-b:11434

GET  /api/tags     → merged list from all online nodes (remote prefixed)
POST /api/chat     → routed by model field
POST /api/generate → routed by model field
All other paths    → forwarded to local
"""

import http.server
import urllib.request
import urllib.error
import json
import threading
import shutil
import sys
import os

PROXY_PORT = 11435
NODES_FILE = "/etc/ollama-cluster/nodes.json"
LOCAL_URL  = "http://localhost:11434"

# ── node registry ────────────────────────────────────────────────────────────

def load_nodes():
    """Return {node_name: base_url}. 'local' is always present."""
    base = {"local": LOCAL_URL}
    try:
        with open(NODES_FILE) as f:
            data = json.load(f)
        base.update(data)
    except Exception:
        pass
    return base


def get_target(model_name):
    """Return (base_url, actual_model_name) for a given model string."""
    nodes = load_nodes()
    for name, url in nodes.items():
        if name != "local" and model_name.startswith(f"{name}/"):
            return url, model_name[len(name) + 1:]
    return LOCAL_URL, model_name


# ── proxy handler ─────────────────────────────────────────────────────────────

class ClusterProxy(http.server.BaseHTTPRequestHandler):

    def _forward(self, target_url, body=None):
        try:
            headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
            req = urllib.request.Request(
                target_url,
                data=body,
                headers=headers if body else {},
                method=self.command,
            )
            with urllib.request.urlopen(req, timeout=300) as resp:
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                        self.send_header(k, v)
                self.end_headers()
                shutil.copyfileobj(resp, self.wfile)
        except urllib.error.HTTPError as e:
            self.send_error(e.code, str(e))
        except Exception as e:
            self.send_error(502, f"Proxy error: {e}")

    # GET ──────────────────────────────────────────────────────────────────────

    def do_GET(self):
        if self.path == "/api/tags":
            self._handle_tags()
        else:
            self._forward(f"{LOCAL_URL}{self.path}")

    def _handle_tags(self):
        nodes = load_nodes()
        all_models = []
        for node_name, node_url in nodes.items():
            try:
                req = urllib.request.Request(f"{node_url}/api/tags", timeout=5)
                with urllib.request.urlopen(req) as r:
                    data = json.loads(r.read())
                for m in data.get("models", []):
                    entry = dict(m)
                    if node_name != "local":
                        entry["name"] = f"{node_name}/{m['name']}"
                    all_models.append(entry)
            except Exception:
                pass

        payload = json.dumps({"models": all_models}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # POST ─────────────────────────────────────────────────────────────────────

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length) if length else b""

        target_base = LOCAL_URL
        body = raw_body

        try:
            req_data = json.loads(raw_body)
            model = req_data.get("model", "")
            target_base, actual_model = get_target(model)
            if actual_model != model:
                req_data["model"] = actual_model
                body = json.dumps(req_data).encode()
        except Exception:
            pass

        self._forward(f"{target_base}{self.path}", body)

    def log_message(self, fmt, *args):
        # Suppress per-request noise; use log_error only for real issues
        pass


# ── entrypoint ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PROXY_PORT), ClusterProxy)
    print(f"Ollama cluster proxy listening on :{PROXY_PORT}", flush=True)
    print(f"  local   → {LOCAL_URL}", flush=True)
    print(f"  nodes   → {NODES_FILE}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
