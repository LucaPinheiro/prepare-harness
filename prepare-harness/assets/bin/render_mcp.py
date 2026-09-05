#!/usr/bin/env python3
"""Projeta mcp/servers.json no formato de config de cada CLI.

Uso: render_mcp.py <servers.json> <claude|devin> [--out <arquivo>]

Sem --out escreve em stdout. Com --out escreve de forma atômica (tmp + rename),
que é o que permite regenerar um arquivo lendo o anterior sem truncá-lo antes.

Só entram os servers com "enabled": true — é assim que se liga/desliga um MCP
sem perder a definição dele.
"""
import json
import os
import sys


def render(servers: dict) -> dict:
    out = {"mcpServers": {}}
    for name, spec in servers.items():
        if not spec.get("enabled", False):
            continue
        transport = spec.get("transport", "stdio")
        if transport == "stdio":
            entry = {"type": "stdio", "command": spec["command"], "args": spec.get("args", [])}
            if spec.get("env"):
                entry["env"] = spec["env"]
        else:  # http | sse — o CLI resolve a URL, não há command local
            entry = {"type": transport, "url": spec["url"]}
            if spec.get("headers"):
                entry["headers"] = spec["headers"]
        out["mcpServers"][name] = entry
    return out


def main() -> int:
    args = [a for a in sys.argv[1:]]
    out_path = None
    if "--out" in args:
        i = args.index("--out")
        out_path = args[i + 1]
        del args[i:i + 2]
    if len(args) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    src, target = args[0], args[1]
    if target not in ("claude", "devin"):
        print(f"target desconhecido: {target} (use claude ou devin)", file=sys.stderr)
        return 2

    with open(src) as f:
        data = json.load(f)
    rendered = render(data.get("servers", {}))
    text = json.dumps(rendered, indent=2, ensure_ascii=False) + "\n"

    if out_path:
        tmp = out_path + ".tmp"
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, out_path)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
