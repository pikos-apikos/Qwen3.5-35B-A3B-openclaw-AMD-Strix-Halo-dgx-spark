#!/usr/bin/env python3
"""Validate openclaw/provider-snippet.json."""
import json
import sys

with open("openclaw/provider-snippet.json") as f:
    data = json.load(f)

providers = data.get("providers", {})
llamacpp = providers.get("llamacpp", {})
if not llamacpp:
    print("ERROR: 'llamacpp' provider not found")
    sys.exit(1)

models = llamacpp.get("models", [])
if not models:
    print("ERROR: no models defined in llamacpp provider")
    sys.exit(1)

m = models[0]
print(f"Provider: llamacpp")
print(f"  baseUrl: {llamacpp.get('baseUrl')}")
print(f"  model id: {m.get('id')}")
print(f"  contextWindow: {m.get('contextWindow')}")
print(f"  reasoning: {m.get('reasoning')}")

required = ["id", "name", "baseUrl"]
for field in required:
    if field not in m:
        print(f"ERROR: missing field '{field}' in model config")
        sys.exit(1)

print("  OK")
print("All checks passed.")