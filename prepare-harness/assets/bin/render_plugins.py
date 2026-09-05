#!/usr/bin/env python3
"""Projeta o catálogo de plugins (e a pré-aprovação de MCP) no .claude/settings.json.

Uso: render_plugins.py <plugins.json> [servers.json] [--out <settings.json>]

  plugins.json -> extraKnownMarketplaces + enabledPlugins
  servers.json -> enabledMcpjsonServers (declara quais MCP do ./.mcp.json o time
                  aprovou; NÃO substitui o diálogo de confiança da pasta, aceito uma
                  vez por máquina — medido: com hasTrustDialogAccepted=false os
                  servers ficam pendentes mesmo com esta chave escrita)

Com --out o arquivo é *mesclado*, não sobrescrito: chaves que não são nossas
(permissions, hooks, env, model…) sobrevivem intactas. Isso importa porque o
settings.json costuma ter configuração escrita à mão que ninguém quer perder num
`harness sync`. Sem --out, imprime só o bloco projetado em stdout.

A remoção também é respeitada: plugin com enabled:false vira `false` e MCP com
enabled:false sai da lista de pré-aprovados — desligar na fonte desliga de fato.
"""
import json
import os
import sys


def load_json(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def main() -> int:
    args = list(sys.argv[1:])
    out_path = None
    if "--out" in args:
        i = args.index("--out")
        out_path = args[i + 1]
        del args[i:i + 2]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2

    catalog = load_json(args[0])
    servers = load_json(args[1]).get("servers", {}) if len(args) > 1 else {}

    # Entradas ainda em TODO- são o template esperando preenchimento: projetá-las
    # sujaria o settings.json com um marketplace que não existe.
    marketplaces = {
        name: {"source": {"source": spec["source"], "repo": spec["repo"]}}
        for name, spec in catalog.get("marketplaces", {}).items()
        if not name.startswith(("TODO","EXEMPLO")) and not str(spec.get("repo","")).startswith(("TODO","EXEMPLO"))
    }
    plugins = {
        key: bool(spec.get("enabled", False))
        for key, spec in catalog.get("plugins", {}).items()
        if not key.startswith(("TODO","EXEMPLO"))
    }
    mcp_on = [n for n, s in servers.items() if s.get("enabled", False)]
    mcp_off = {n for n, s in servers.items() if not s.get("enabled", False)}

    settings = {}
    if out_path and os.path.exists(out_path):
        try:
            settings = load_json(out_path)
        except json.JSONDecodeError:
            print(f"aviso: {out_path} não é JSON válido — reescrevendo do zero", file=sys.stderr)
            settings = {}

    settings.setdefault("extraKnownMarketplaces", {}).update(marketplaces)
    settings.setdefault("enabledPlugins", {}).update(plugins)

    if servers:
        previous = [n for n in settings.get("enabledMcpjsonServers", []) if n not in mcp_off]
        merged = previous + [n for n in mcp_on if n not in previous]
        if merged:
            settings["enabledMcpjsonServers"] = merged
        else:
            settings.pop("enabledMcpjsonServers", None)

    for key in ("extraKnownMarketplaces", "enabledPlugins"):
        if not settings.get(key):
            settings.pop(key, None)

    text = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
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
