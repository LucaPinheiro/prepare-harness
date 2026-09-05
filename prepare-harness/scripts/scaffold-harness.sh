#!/usr/bin/env bash
# scaffold-harness — cria o esqueleto genérico de um harness no diretório alvo.
#
# Tudo que ele escreve é template com TODO explícito: a ideia é que a estrutura
# venha pronta e só o conteúdo do seu time precise de mão. Nunca sobrescreve um
# arquivo existente (sem --force), então rodar de novo num harness já montado só
# preenche o que faltava.
set -euo pipefail

FORCE=0; COPY_SKILL=1; TARGET=""

usage() {
  cat <<'USAGE'
uso: scaffold-harness.sh [diretório] [opções]

  diretório         onde criar o harness (padrão: diretório atual)
  --force           sobrescreve arquivos existentes (o padrão é preservar)
  --no-skill-copy   não copia a skill prepare-harness pro catalog/ do alvo
  -h, --help        esta ajuda

Depois do scaffold:
  1. preencha os TODO (harness.config.yaml, workspace/repositories.md, mcp/, catalog/plugins/)
  2. bash catalog/skills/prepare-harness/scripts/prepare-harness.sh
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --force)         FORCE=1 ;;
    --no-skill-copy) COPY_SKILL=0 ;;
    -h|--help)       usage; exit 0 ;;
    -*) echo "flag desconhecida: $arg" >&2; usage >&2; exit 2 ;;
    *)  TARGET="$arg" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS="$SKILL_DIR/assets"
[ -d "$ASSETS" ] || { echo "✗ assets não encontrados em $ASSETS"; exit 1; }

TARGET="${TARGET:-$PWD}"
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"

CREATED=0; KEPT=0
place() { # $1=origem $2=destino relativo ao TARGET
  local src="$1" dst="$TARGET/$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ "$FORCE" -eq 0 ]; then
    echo "  = $2 (já existe, preservado)"; KEPT=$((KEPT+1)); return 0
  fi
  cp "$src" "$dst"
  echo "  + $2"; CREATED=$((CREATED+1))
}

echo "scaffold em: $TARGET"
echo ""
echo "→ estrutura"
mkdir -p "$TARGET"/{bin,catalog/skills,catalog/plugins,mcp,agents,workspace}
: > /dev/null

# ── fonte canônica ───────────────────────────────────────────────────────────
place "$ASSETS/harness.config.yaml"            harness.config.yaml
place "$ASSETS/AGENTS.md"                      AGENTS.md
place "$ASSETS/catalog/plugins/plugins.json"   catalog/plugins/plugins.json
place "$ASSETS/workspace/repositories.md"      workspace/repositories.md

# ── ferramentas ──────────────────────────────────────────────────────────────
place "$ASSETS/bin/harness"                    bin/harness
place "$ASSETS/bin/render_mcp.py"              bin/render_mcp.py
place "$ASSETS/bin/render_plugins.py"          bin/render_plugins.py
chmod +x "$TARGET/bin/harness" "$TARGET/bin/render_mcp.py" "$TARGET/bin/render_plugins.py" 2>/dev/null || true

touch "$TARGET/workspace/.gitkeep" "$TARGET/agents/.gitkeep"

# ── mcp/servers.json: importa um .mcp.json existente em vez de atropelá-lo ───
# O .mcp.json vira uma *projeção* a partir daqui. Se o projeto já tinha um escrito
# à mão, perder essa config no primeiro `sync` seria o pior jeito de começar.
if [ -f "$TARGET/mcp/servers.json" ] && [ "$FORCE" -eq 0 ]; then
  echo "  = mcp/servers.json (já existe, preservado)"; KEPT=$((KEPT+1))
elif [ -f "$TARGET/.mcp.json" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$TARGET/.mcp.json" "$TARGET/mcp/servers.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
servers = {}
for name, spec in json.load(open(src)).get("mcpServers", {}).items():
    transport = spec.get("type") or ("stdio" if spec.get("command") else "http")
    entry = {"transport": transport, "enabled": True,
             "purpose": "importado do .mcp.json existente"}
    if transport == "stdio":
        entry["command"] = spec.get("command", "")
        entry["args"] = spec.get("args", [])
        if spec.get("env"):
            entry["env"] = spec["env"]
    else:
        entry["url"] = spec.get("url", "")
        if spec.get("headers"):
            entry["headers"] = spec["headers"]
    servers[name] = entry
out = {"_note": "Fonte canônica dos MCP servers. Importado do .mcp.json que já existia neste projeto — a partir de agora o .mcp.json é gerado daqui por `harness sync`. Credenciais em ${VAR}, nunca literais.",
       "servers": servers}
json.dump(out, open(dst, "w"), indent=2, ensure_ascii=False)
open(dst, "a").write("\n")
print(f"  + mcp/servers.json (importado de .mcp.json: {', '.join(servers) or 'vazio'})")
PY
  CREATED=$((CREATED+1))
else
  place "$ASSETS/mcp/servers.json" mcp/servers.json
fi

# ── a própria skill, pra o harness nascer autossuficiente ────────────────────
if [ "$COPY_SKILL" -eq 1 ]; then
  DEST_SKILL="$TARGET/catalog/skills/prepare-harness"
  if [ "$(cd "$SKILL_DIR" && pwd -P)" = "$(cd "$DEST_SKILL" 2>/dev/null && pwd -P || echo '')" ]; then
    echo "  = catalog/skills/prepare-harness (é a própria origem)"
  elif [ -d "$DEST_SKILL" ] && [ "$FORCE" -eq 0 ]; then
    echo "  = catalog/skills/prepare-harness (já existe, preservado)"; KEPT=$((KEPT+1))
  else
    mkdir -p "$DEST_SKILL"
    cp -R "$SKILL_DIR/." "$DEST_SKILL/"
    echo "  + catalog/skills/prepare-harness (skill copiada)"; CREATED=$((CREATED+1))
  fi
fi

# ── .gitignore ───────────────────────────────────────────────────────────────
# Bloco marcado e idempotente: append só se o marcador ainda não estiver lá,
# preservando o que o projeto já ignorava.
GI="$TARGET/.gitignore"
WORKSPACE_DIR="$(awk '/^workspace_dir:[[:space:]]/{sub(/^[^:]*:[[:space:]]*/,"");sub(/[[:space:]]*#.*/,"");print;exit}' "$TARGET/harness.config.yaml")"
WORKSPACE_DIR="${WORKSPACE_DIR:-workspace}"
REGISTRY="$(awk '/^registry:[[:space:]]/{sub(/^[^:]*:[[:space:]]*/,"");sub(/[[:space:]]*#.*/,"");print;exit}' "$TARGET/harness.config.yaml")"
REGISTRY="${REGISTRY:-$WORKSPACE_DIR/repositories.md}"
VENDOR_DIR="$(awk '/^skills_vendor_dir:[[:space:]]/{sub(/^[^:]*:[[:space:]]*/,"");sub(/[[:space:]]*#.*/,"");print;exit}' "$TARGET/harness.config.yaml")"
VENDOR_DIR="${VENDOR_DIR:-catalog/skills-vendor}"
if [ -f "$GI" ] && grep -q '>>> harness (prepare-harness) >>>' "$GI"; then
  echo "  = .gitignore (bloco do harness já presente)"; KEPT=$((KEPT+1))
else
  [ -f "$GI" ] && echo "" >> "$GI"
  sed -e "s#@@WORKSPACE@@#$WORKSPACE_DIR#g" -e "s#@@REGISTRY@@#$REGISTRY#g" \
      -e "s#@@VENDOR@@#$VENDOR_DIR#g" \
    "$ASSETS/gitignore.block" >> "$GI"
  echo "  + .gitignore (bloco do harness)"; CREATED=$((CREATED+1))
fi

# ── resumo ───────────────────────────────────────────────────────────────────
cat <<EOF

── scaffold pronto ────────────────────────────────
  $CREATED criado(s), $KEPT preservado(s)

Preencha, nesta ordem (procure por TODO):
  1. harness.config.yaml        nome, tools, repo_filter, skill_repos, post_clone
  2. workspace/repositories.md  a tabela de repos do time (qualquer host git)
  3. mcp/servers.json           quais MCP ficam enabled
  4. catalog/plugins/plugins.json  marketplaces e plugins do Claude Code
  5. AGENTS.md                  o contexto que todo agente deve ler

Depois:
  cd $TARGET
  ./bin/harness doctor    # mostra o que ainda está por preencher
  bash catalog/skills/prepare-harness/scripts/prepare-harness.sh
EOF
