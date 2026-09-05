#!/usr/bin/env bash
# prepare-harness — deixa este harness pronto pra uso: plugins, skills externos,
# MCP project-scope e os clones da workspace. Idempotente: rodar de novo é seguro
# e barato, então é o comando certo tanto no onboarding quanto quando "faltou repo".
#
# Cada etapa que depende de um binário opcional (claude, npx, gh, python3) é
# best-effort: ela avisa e segue. O motivo é que um setup pela metade que reporta
# o que faltou vale mais que um script que aborta na primeira ausência.
set -euo pipefail

DO_SCAFFOLD=0; DO_SYNC=1; DO_PULL=1
DO_PLUGINS=1; DO_SKILLS=1; DO_MCP=1; DO_CLONE=1; DO_POST=1; DO_SKILL_REPOS=1
DRY=0; LIST_ONLY=0; KEEP_VENDOR=0

usage() {
  cat <<'USAGE'
uso: prepare-harness.sh [opções]

  --scaffold      cria o esqueleto do harness antes de preparar (delega no
                  scaffold-harness.sh) — use no primeiro setup de um repo vazio
  --no-sync       não roda a projeção final (./bin/harness sync)
  --no-pull       não atualiza repos já clonados, só clona os que faltam
  --no-plugins    pula a instalação dos plugins do Claude Code
  --no-skill-repos pula o clone/link das skills vindas de repos git
  --keep-vendor   preserva os clones de skill_repos em skills_vendor_dir em vez
                  de apagá-los depois de copiar pro catálogo (debug)
  --no-skills     pula a instalação dos pacotes de skills externos (npx)
  --no-mcp        pula a projeção do ./.mcp.json e da pré-aprovação de MCP
  --no-clone      pula os clones da workspace
  --no-post-clone pula os comandos post_clone
  --list          só lista os repos declarados no registry e sai
  --dry-run       mostra o que faria, sem executar
  -h, --help      esta ajuda
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --scaffold)      DO_SCAFFOLD=1 ;;
    --no-sync)       DO_SYNC=0 ;;
    --no-pull)       DO_PULL=0 ;;
    --no-plugins)    DO_PLUGINS=0 ;;
    --no-skill-repos) DO_SKILL_REPOS=0 ;;
    --keep-vendor)   KEEP_VENDOR=1 ;;
    --no-skills)     DO_SKILLS=0 ;;
    --no-mcp)        DO_MCP=0 ;;
    --no-clone)      DO_CLONE=0 ;;
    --no-post-clone) DO_POST=0 ;;
    --list)          LIST_ONLY=1 ;;
    --dry-run)       DRY=1 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "flag desconhecida: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Diretório da skill à qual ESTE script pertence. Serve de guarda-corpo no import:
# prepare-harness é o bootstrap do harness e não pode se trocar no meio do próprio run.
SELF_SKILL="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "")"

# Um repo inacessível (privado sem permissão, URL errada, host fora do ar) faz o
# git PEDIR usuário e senha no stdin — num script isso não falha, trava para
# sempre. Estas três variáveis transformam esse caso num erro rápido, que é o que
# o resumo de pendências sabe reportar.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=""
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}"

# ── raiz do harness ──────────────────────────────────────────────────────────
# Sobe a partir do diretório atual procurando o harness.config.yaml. Isso deixa o
# script funcionar de qualquer subdiretório, inclusive de dentro de um clone da
# workspace (que tem git próprio, então `git rev-parse` sozinho apontaria errado).
# Procura primeiro a partir do PWD (o caso normal: você está dentro do harness) e
# depois a partir do próprio script — que resolve o caso de invocar por caminho
# absoluto, de fora, como um agente costuma fazer.
find_root() {
  local base p
  for base in "$PWD" "$SCRIPT_DIR"; do
    p="$base"
    while [ "$p" != "/" ]; do
      [ -f "$p/harness.config.yaml" ] && { echo "$p"; return 0; }
      p="$(dirname "$p")"
    done
  done
  return 1
}

if [ "$DO_SCAFFOLD" -eq 1 ]; then
  bash "$SCRIPT_DIR/scaffold-harness.sh" "$PWD"
  echo ""
fi

ROOT="$(find_root || true)"
if [ -z "$ROOT" ]; then
  cat >&2 <<MSG
✗ harness.config.yaml não encontrado (nem aqui nem nos diretórios acima).

  Se este é um harness novo, crie o esqueleto primeiro:
    bash $SCRIPT_DIR/scaffold-harness.sh .
  ou rode este script com --scaffold.
MSG
  exit 1
fi
CFG="$ROOT/harness.config.yaml"
cd "$ROOT"

# ── leitura do config (YAML simples, sem PyYAML) ─────────────────────────────
yaml_list() {
  awk -v k="$1" '
    $0 ~ "^"k":[[:space:]]*$" {f=1; next}
    f && /^[[:space:]]*#/ {next}
    f && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]*/,""); sub(/[[:space:]]*#.*/,"");
      gsub(/^["'"'"']|["'"'"']$/,""); print; next
    }
    f && /^[^[:space:]#]/ {f=0}
  ' "$CFG"
}
yaml_scalar() {
  local v
  v="$(awk -v k="$1" '$0 ~ "^"k":[[:space:]]" {sub(/^[^:]*:[[:space:]]*/,""); sub(/[[:space:]]*#.*/,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$CFG")"
  [ -n "$v" ] && echo "$v" || echo "${2:-}"
}
trim() { echo "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

NAME="$(yaml_scalar name 'harness')"
WORKSPACE_DIR="$(yaml_scalar workspace_dir workspace)"
REGISTRY="$(yaml_scalar registry "$WORKSPACE_DIR/repositories.md")"
CLONE_PROTOCOL="$(yaml_scalar clone_protocol https)"
SKILLS_SCOPE="$(yaml_scalar skills_scope project)"
WORKSPACE="$ROOT/$WORKSPACE_DIR"
REG="$ROOT/$REGISTRY"

say()  { echo "$@"; }
run()  { if [ "$DRY" -eq 1 ]; then echo "    [dry-run] $*"; else eval "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── extração dos repos do registry ───────────────────────────────────────────
# Aceita qualquer host git (GitHub, GitLab, Bitbucket, self-hosted) em HTTPS ou
# SSH. Só casa URLs com exatamente owner/repo: um link de documentação com mais
# segmentos (host/a/b/c) não vira clone por engano.
extract_repos() {
  [ -f "$REG" ] || return 0
  local filters; filters="$(yaml_list repo_filter | sed '/^$/d')"
  # Comentário HTML no registry é intenção explícita de "não clonar isto" — vale
  # tanto pros exemplos do template quanto pra um repo desativado temporariamente.
  # Só linhas de tabela ou de lista viram clone. Prosa e blockquote ficam de fora
  # de propósito: o próprio texto do registry cita "git@host:owner/repo.git" como
  # exemplo de formato, e clonar a documentação seria um jeito bobo de falhar.
  # O `|| true` importa: com pipefail, um grep sem match derrubaria o script.
  local raw
  raw="$(sed -e 's/<!--.*-->//g' -e '/<!--/,/-->/d' "$REG" \
    | grep -E '^[[:space:]]*[|*-]' \
    | sed 's/$/ /' \
    | grep -oE '(https?://[A-Za-z0-9._-]+(:[0-9]+)?/[A-Za-z0-9._~-]+/[A-Za-z0-9._-]+(\.git)?|git@[A-Za-z0-9._-]+:[A-Za-z0-9._~-]+/[A-Za-z0-9._-]+(\.git)?)[^A-Za-z0-9._/~-]' \
    | sed -E 's/[^A-Za-z0-9._/~:-]+$//; s/[.,;:)]+$//; s/\.git$//' \
    | sort -u || true)"
  [ -n "$raw" ] || return 0
  echo "$raw" \
  | while IFS= read -r url; do
      [ -z "$url" ] && continue
      # placeholder do template: ainda não é um repo de verdade
      case "$url" in *TODO*) continue ;; esac
      if [ -n "$filters" ]; then
        # normaliza pra host/owner/repo, então um filtro "github.com/minha-org"
        # casa tanto com a URL HTTPS quanto com a SSH (git@github.com:minha-org/x)
        local norm keep=0
        norm="$(echo "$url" | sed -E 's#^[a-z][a-z0-9+.-]*://##; s#^git@##; s#:#/#')"
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          case "$norm" in "$f"|"$f"/*) keep=1 ;; esac
        done <<< "$filters"
        [ "$keep" -eq 1 ] || continue
      fi
      echo "$url"
    done
}

repo_name() { basename "${1%.git}"; }
repo_host() {
  case "$1" in
    git@*) echo "${1#git@}" | cut -d: -f1 ;;
    *)     echo "$1" | sed -E 's#^[a-z]+://##' | cut -d/ -f1 ;;
  esac
}
repo_slug() { # owner/repo
  case "$1" in
    git@*) echo "${1#*:}" | sed 's#\.git$##' ;;
    *)     echo "$1" | sed -E 's#^[a-z]+://[^/]+/##; s#\.git$##' ;;
  esac
}
to_ssh() { echo "git@$(repo_host "$1"):$(repo_slug "$1").git"; }
same_remote() { # $1=url_config $2=url_atual
  local a b
  a="$(repo_host "$1")/$(repo_slug "$1")"; b="$(repo_host "$2")/$(repo_slug "$2")"
  [ "$a" = "$b" ]
}

if [ "$LIST_ONLY" -eq 1 ]; then extract_repos; exit 0; fi

say "harness: $NAME  ($ROOT)"
[ "$DRY" -eq 1 ] && say "(dry-run — nada será alterado)"
say ""

# ── pré-requisitos ───────────────────────────────────────────────────────────
have git || { echo "✗ git não encontrado — é o único requisito duro"; exit 1; }

SUMMARY_PLUGINS="pulado"; SUMMARY_SKILLS="pulado"; SUMMARY_MCP="pulado"
SUMMARY_VENDOR="pulado"; SUMMARY_SYNC="pulado"
FAILURES=""

# ── 1. plugins do Claude Code ────────────────────────────────────────────────
# A fonte é catalog/plugins/plugins.json; aqui a gente executa de fato o `claude
# plugin` CLI. O `-y` é obrigatório fora de TTY (o install confirma o comando do
# marketplace) e o `--scope user` é o padrão do CLI.
install_plugins() {
  local pj="$ROOT/catalog/plugins/plugins.json"
  [ -f "$pj" ] || { SUMMARY_PLUGINS="sem catalog/plugins/plugins.json"; return 0; }
  if ! have claude; then
    say "→ plugins: claude CLI ausente — pulando (o .claude/settings.json projetado resolve no próximo start)"
    SUMMARY_PLUGINS="pulado (claude ausente)"; return 0
  fi
  have python3 || { say "→ plugins: python3 ausente — pulando"; SUMMARY_PLUGINS="pulado (python3 ausente)"; return 0; }

  # entradas TODO- são o template esperando preenchimento, não plugins reais
  local declared
  declared="$(python3 -c 'import json,sys
print(len([k for k in json.load(open(sys.argv[1])).get("plugins",{}) if not k.startswith(("TODO","EXEMPLO"))]))' "$pj")"
  if [ "$declared" -eq 0 ]; then
    say "→ plugins: nenhum plugin declarado ainda (só placeholders TODO) — pulando"
    SUMMARY_PLUGINS="nenhum declarado"; return 0
  fi

  say "→ plugins do Claude Code"
  local n_ok=0 n_off=0 n_fail=0

  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    run "claude plugin marketplace add \"$repo\" >/dev/null 2>&1 || true"
  done < <(python3 -c 'import json,sys
for s in json.load(open(sys.argv[1])).get("marketplaces",{}).values():
    r = s.get("repo") or s.get("source_url") or ""
    if r and not r.startswith(("TODO","EXEMPLO")): print(r)' "$pj")

  local installed; installed="$(claude plugin list 2>/dev/null || true)"
  local tmp; tmp="$(mktemp)"
  python3 -c 'import json,sys
for k,s in json.load(open(sys.argv[1])).get("plugins",{}).items():
    if k.startswith(("TODO","EXEMPLO")): continue
    print(("1" if s.get("enabled") else "0")+"\t"+k)' "$pj" > "$tmp"

  while IFS=$'\t' read -r en key; do
    [ -z "${key:-}" ] && continue
    if [ "$en" = "1" ]; then
      if printf '%s\n' "$installed" | grep -q -- "${key%@*}"; then
        run "claude plugin enable \"$key\" >/dev/null 2>&1 || true"
        say "  ✓ $key (já instalado, habilitado)"; n_ok=$((n_ok+1))
      elif [ "$DRY" -eq 1 ]; then
        say "    [dry-run] claude plugin install --yes $key"; n_ok=$((n_ok+1))
      elif claude plugin install --yes "$key" >/dev/null 2>&1; then
        say "  ✓ $key instalado"; n_ok=$((n_ok+1))
      else
        say "  ✗ $key — falha ao instalar (o nome é <plugin>@<marketplace>, e o marketplace é o campo name do marketplace.json)"
        n_fail=$((n_fail+1)); FAILURES="$FAILURES\n  plugin $key"
      fi
    else
      run "claude plugin disable \"$key\" >/dev/null 2>&1 || true"
      say "  • $key desabilitado (enabled:false)"; n_off=$((n_off+1))
    fi
  done < "$tmp"
  rm -f "$tmp"
  SUMMARY_PLUGINS="$n_ok habilitado(s), $n_off desabilitado(s), $n_fail falha(s)"
}
[ "$DO_PLUGINS" -eq 1 ] && install_plugins

# ── 2. skills vindas de repositórios git ─────────────────────────────────────
# Clona cada repo de skills e COPIA toda pasta com SKILL.md para catalog/skills.
# Cópia, e não link, porque catalog/ é a fonte canônica do harness e é versionada:
# quem clona o harness recebe a biblioteca inteira sem rede e sem passo extra — e
# os links em .claude/skills viram projeção normal, como as demais.
#
# O marcador .vendored-from registra a origem de cada cópia. É ele que autoriza a
# atualização automática: sem marcador, o diretório foi escrito pelo time e o
# import não encosta nele.
#
# O clone é EFÊMERO: assim que as skills são copiadas, o diretório do repo é
# apagado (e skills_vendor_dir junto, se ficar vazio). O que fica no harness é o
# catálogo, não o checkout — é ele que é versionado e é dele que o `sync` projeta.
# Por isso o clone é sempre `--depth 1` e sempre novo: sem checkout persistido não
# há `pull` incremental, e não faz falta, porque um clone raso de um repo de skills
# custa menos que a confusão de manter uma árvore git parada dentro do catálogo.
# `--keep-vendor` preserva o checkout (debug: inspecionar o que veio do upstream).
import_skills() {
  local repos; repos="$(yaml_list skill_repos | sed '/^$/d; /TODO/d')"
  if [ -z "$repos" ]; then
    say "→ skills git: nenhum repo declarado (skill_repos vazio) — pulando"
    SUMMARY_VENDOR="nenhum repo"; return 0
  fi
  local vdir_rel; vdir_rel="$(yaml_scalar skills_vendor_dir catalog/skills-vendor)"
  local vdir="$ROOT/$vdir_rel"
  say "→ skills git (→ catalog/skills)"
  # Em dry-run nem o staging é criado: "não altera nada" tem que valer para o
  # diretório vazio também, senão o dry-run deixa lixo que ele mesmo não limpa.
  [ "$DRY" -eq 0 ] && mkdir -p "$vdir" "$ROOT/catalog/skills"

  local n_repo=0 n_new=0 n_upd=0 n_skip=0
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    local rname dest; rname="$(repo_name "$url")"; dest="$vdir/$rname"

    if [ -d "$dest/.git" ]; then
      if [ "$DRY" -eq 1 ]; then say "    [dry-run] git -C $dest pull"
      elif [ "$DO_PULL" -eq 1 ] && git -C "$dest" pull --ff-only --quiet 2>/dev/null; then
        say "  ✓ $rname (upstream atualizado)"
      else
        say "  ✓ $rname (upstream já clonado)"
      fi
    elif [ "$DRY" -eq 1 ]; then
      say "    [dry-run] clone $url -> $dest"
    elif git clone --quiet --depth 1 "$url" "$dest" >/dev/null 2>&1; then
      say "  ✓ $rname clonado"
    else
      say "  ✗ $rname — falha no clone do repo de skills"
      FAILURES="$FAILURES\n  skills git $rname"; continue
    fi
    n_repo=$((n_repo+1))
    [ "$DRY" -eq 1 ] && continue

    # Cada diretório com SKILL.md é uma skill. A ordem lexicográfica garante que um
    # diretório-pai apareça antes dos filhos, então um SKILL.md aninhado dentro de
    # outra skill (referência, exemplo) não vira uma segunda skill.
    local accepted="" sk skname target marker origin
    while IFS= read -r sk; do
      [ -z "$sk" ] && continue
      case "$accepted" in *"|$sk/"*) continue ;; esac
      accepted="$accepted|$sk/"
      # A identidade de uma skill é o `name:` do frontmatter, não o nome da pasta.
      # Os dois divergem com frequência (a skill do graphify mora em `graphifyy/`,
      # o nome do pacote PyPI, mas se chama `graphify`, o nome do comando) — e é o
      # `name:` que o CLI usa para resolver a invocação.
      skname="$(sed -n '1,20p' "$sk/SKILL.md" 2>/dev/null \
        | sed -n 's/^name:[[:space:]]*//p' | head -1 \
        | tr -d '"'"'"'\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      case "$skname" in
        ""|.*|*/*|*[!A-Za-z0-9._-]*)
          skname="$(basename "$sk")" ;;   # frontmatter ausente ou suspeito: usa a pasta
      esac
      case "$skname" in ""|.*|*/*) continue ;; esac
      [ "$skname" = "$(basename "$sk")" ] || say "    · $(basename "$sk")/ → $skname (nome do frontmatter)"
      target="$ROOT/catalog/skills/$skname"
      # guarda-corpo: só mexe dentro de catalog/skills, nunca em outro caminho
      case "$target" in "$ROOT/catalog/skills/"?*) ;; *) continue ;; esac
      # guarda-corpo de bootstrap: nunca sobrescrever a skill que está executando
      # este script. Quem levanta o harness não pode se trocar no meio do próprio
      # run — sobra uma árvore que ninguém verificou, e a edição local some sem
      # aviso. Só o Unix (rm desvincula, o fd segue no inode antigo) evita o
      # desastre, e isso é acidente, não desenho. Atualizar o bootstrap é ato
      # deliberado: scaffold-harness.sh --force.
      if [ -n "$SELF_SKILL" ] && [ "$target" = "$SELF_SKILL" ]; then
        say "    ~ $skname — é a skill que está rodando este script; não me sobrescrevo"
        say "      (para atualizar o bootstrap: scaffold-harness.sh --force, a partir do repo de origem)"
        n_skip=$((n_skip+1)); continue
      fi
      origin="$url#${sk#$dest/}"
      marker="$target/.vendored-from"

      if [ -e "$target" ]; then
        if [ ! -f "$marker" ]; then
          say "    ! $skname — já existe em catalog/skills sem marcador de origem; não toquei"
          n_skip=$((n_skip+1)); continue
        fi
        if [ "$(head -1 "$marker" 2>/dev/null)" != "$origin" ]; then
          say "    ! $skname — veio de outra origem; não toquei"
          n_skip=$((n_skip+1)); continue
        fi
        rm -rf "$target"; cp -R "$sk" "$target"; n_upd=$((n_upd+1))
      else
        cp -R "$sk" "$target"; n_new=$((n_new+1))
      fi
      printf '%s\n%s\n' "$origin" \
        "# Cópia gerenciada por prepare-harness (skill_repos): edite no repo de origem, porque o próximo setup sobrescreve este diretório. Para adotar a skill como sua, apague este arquivo." > "$marker"
    done < <(find "$dest" -name SKILL.md -not -path "*/.git/*" 2>/dev/null | sed 's#/SKILL\.md$##' | sort)

    # Catálogo populado: o checkout já cumpriu o papel dele. O guarda-corpo do
    # case é o que impede um skills_vendor_dir mal preenchido (vazio, "/", "..")
    # de virar um rm -rf em cima do harness.
    if [ "$KEEP_VENDOR" -eq 0 ]; then
      case "$dest" in
        "$vdir"/?*) rm -rf "$dest"; say "    · checkout de $rname descartado (o que vale é o catálogo)" ;;
      esac
    fi
  done <<< "$repos"

  # Só remove o diretório de staging se ele ficou vazio — se alguém guardou algo
  # ali dentro, o rmdir falha de propósito e o conteúdo fica.
  [ "$KEEP_VENDOR" -eq 0 ] && [ "$DRY" -eq 0 ] && rmdir "$vdir" 2>/dev/null || true

  if [ "$DRY" -eq 0 ]; then
    local extra=""
    [ "$n_skip" -gt 0 ] && extra=", $n_skip ignorada(s)"
    say "  ✓ $n_new nova(s), $n_upd atualizada(s)$extra no catálogo"
    say "    (catálogo = banco de reservas; escalar é decisão sua: ./bin/harness skills)"
    SUMMARY_VENDOR="$n_new nova(s), $n_upd atualizada(s)$extra de $n_repo repo(s)"
  else
    SUMMARY_VENDOR="dry-run"
  fi
}
[ "$DO_SKILL_REPOS" -eq 1 ] && import_skills

# ── 3. pacotes de skills externos ────────────────────────────────────────────
# `skills add` é interativo por padrão (pergunta quais skills e quais agentes).
# O --all é o que torna a etapa automatizável: equivale a --skill '*' --agent '*' -y.
install_skills() {
  local sources; sources="$(yaml_list skills_sources | sed '/^$/d; /TODO/d')"
  [ -n "$sources" ] || { say "→ skills externos: nenhuma fonte declarada (skills_sources vazio) — pulando"; SUMMARY_SKILLS="nenhuma fonte"; return 0; }
  if ! have npx; then
    say "→ skills externos: npx (Node.js) ausente — pulando"
    SUMMARY_SKILLS="pulado (npx ausente)"; return 0
  fi
  local scope_flag="--project"; [ "$SKILLS_SCOPE" = "global" ] && scope_flag="--global"
  say "→ skills externos (npx skills add $scope_flag --all)"
  local n_ok=0 n_fail=0
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    if [ "$DRY" -eq 1 ]; then say "    [dry-run] npx --yes skills add $src $scope_flag --all"; n_ok=$((n_ok+1)); continue; fi
    if npx --yes skills add "$src" "$scope_flag" --all >/dev/null 2>&1; then
      say "  ✓ $src"; n_ok=$((n_ok+1))
    else
      say "  ✗ $src — falha (repo acessível? tente rodar sem o silenciamento pra ver o erro)"
      n_fail=$((n_fail+1)); FAILURES="$FAILURES\n  skills $src"
    fi
  done <<< "$sources"
  SUMMARY_SKILLS="$n_ok ok, $n_fail falha(s)"
}
[ "$DO_SKILLS" -eq 1 ] && install_skills

# ── 4. MCP project-scope ─────────────────────────────────────────────────────
# ./.mcp.json (raiz do repo) é o ÚNICO lugar de onde o Claude Code lê MCP de
# projeto. A pré-aprovação (enabledMcpjsonServers) vai no .claude/settings.json e
# é o que evita o prompt de "trust" a cada abertura.
ensure_mcp() {
  local src="$ROOT/mcp/servers.json" rm_="$ROOT/bin/render_mcp.py" rp="$ROOT/bin/render_plugins.py"
  [ -f "$src" ] || { say "→ mcp: mcp/servers.json ausente — pulando"; SUMMARY_MCP="sem fonte"; return 0; }
  [ -f "$rm_" ] || { say "→ mcp: bin/render_mcp.py ausente — pulando"; SUMMARY_MCP="sem renderer"; return 0; }
  have python3 || { say "→ mcp: python3 ausente — pulando"; SUMMARY_MCP="pulado (python3 ausente)"; return 0; }

  if [ "$DRY" -eq 1 ]; then say "    [dry-run] render .mcp.json + .claude/settings.json"; SUMMARY_MCP="dry-run"; return 0; fi
  if python3 "$rm_" "$src" claude --out "$ROOT/.mcp.json"; then
    local names; names="$(python3 -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1]))["mcpServers"]))' "$ROOT/.mcp.json" 2>/dev/null)"
    say "→ mcp project-scope (./.mcp.json): ${names:-nenhum server enabled}"
    SUMMARY_MCP="${names:-nenhum server enabled}"
  else
    say "✗ mcp: falha ao renderizar ./.mcp.json"; SUMMARY_MCP="falha"; return 0
  fi

  if [ -f "$rp" ] && [ -f "$ROOT/catalog/plugins/plugins.json" ]; then
    mkdir -p "$ROOT/.claude"
    if python3 "$rp" "$ROOT/catalog/plugins/plugins.json" "$src" --out "$ROOT/.claude/settings.json" && [ -n "${names:-}" ]; then
      say "  pré-aprovados em .claude/settings.json (enabledMcpjsonServers): ${names}"
    fi
  fi
}
[ "$DO_MCP" -eq 1 ] && ensure_mcp

# ── 5. clones da workspace ───────────────────────────────────────────────────
CLONED=0; UPDATED=0; EXISTING=0; FAILED=0; DECLARED=0
clone_workspace() {
  if [ ! -f "$REG" ]; then
    say "→ workspace: registry '$REGISTRY' não encontrado — pulando os clones"
    return 0
  fi
  mkdir -p "$WORKSPACE"

  local tmp; tmp="$(mktemp)"; extract_repos > "$tmp"
  DECLARED="$(grep -c . "$tmp" || true)"
  if [ "$DECLARED" -eq 0 ]; then
    say "→ workspace: nenhuma URL git encontrada em $REGISTRY (preencha a tabela de repos)"
    rm -f "$tmp"; return 0
  fi
  say "→ workspace: $DECLARED repo(s) declarado(s) em $REGISTRY"

  local gh_ok=0
  if have gh && gh auth status >/dev/null 2>&1; then gh_ok=1; fi

  while IFS= read -r url; do
    [ -z "$url" ] && continue
    local name dest slug host
    name="$(repo_name "$url")"; dest="$WORKSPACE/$name"
    slug="$(repo_slug "$url")"; host="$(repo_host "$url")"

    if [ -d "$dest/.git" ]; then
      local current; current="$(git -C "$dest" remote get-url origin 2>/dev/null || echo '')"
      if [ -n "$current" ] && ! same_remote "$url" "$current"; then
        say "  ! $name — já existe apontando pra outro remote ($current); não toquei"
        FAILED=$((FAILED+1)); FAILURES="$FAILURES\n  $name (remote divergente)"
        continue
      fi
      if [ "$DO_PULL" -eq 1 ]; then
        if [ "$DRY" -eq 1 ]; then say "    [dry-run] git -C $dest pull --ff-only"; UPDATED=$((UPDATED+1))
        elif git -C "$dest" pull --ff-only --quiet 2>/dev/null; then
          say "  ✓ $name (atualizado)"; UPDATED=$((UPDATED+1))
        else
          say "  ✓ $name (pull pulado — branch divergente, sem upstream ou offline)"; EXISTING=$((EXISTING+1))
        fi
      else
        say "  ✓ $name (já clonado)"; EXISTING=$((EXISTING+1))
      fi
      continue
    fi
    if [ -e "$dest" ]; then
      say "  ! $name — $dest existe e não é um repo git; não toquei"
      FAILED=$((FAILED+1)); FAILURES="$FAILURES\n  $name (destino ocupado)"
      continue
    fi

    if [ "$DRY" -eq 1 ]; then say "    [dry-run] clone $url -> $dest"; CLONED=$((CLONED+1)); continue; fi
    say "  → clonando $name ..."
    local ok=0
    if [ "$host" = "github.com" ] && [ "$gh_ok" -eq 1 ]; then
      gh repo clone "$slug" "$dest" -- --quiet >/dev/null 2>&1 && ok=1
    fi
    if [ "$ok" -eq 0 ]; then
      local target="$url"
      [ "$CLONE_PROTOCOL" = "ssh" ] && [ "${url#git@}" = "$url" ] && target="$(to_ssh "$url")"
      git clone --quiet "$target" "$dest" >/dev/null 2>&1 && ok=1
    fi
    if [ "$ok" -eq 1 ]; then
      say "  ✓ $name clonado"; CLONED=$((CLONED+1))
    else
      say "  ✗ $name — falha no clone (repo privado sem acesso? host inalcançável?)"
      [ "$host" = "github.com" ] && [ "$gh_ok" -eq 0 ] && say "     dica: repos privados do GitHub precisam de 'gh auth login'"
      FAILED=$((FAILED+1)); FAILURES="$FAILURES\n  $name (clone)"
    fi
  done < "$tmp"
  rm -f "$tmp"
}
[ "$DO_CLONE" -eq 1 ] && clone_workspace

# ── 6. comandos pós-clone ────────────────────────────────────────────────────
# Rodam dentro de cada repo da workspace. É aqui que entram hooks de grafo,
# instalação de dependências, etc — sem que o script precise conhecer a stack.
POST_RESULT=""
run_post_clone() {
  local items; items="$(yaml_list post_clone | sed '/^$/d')"
  [ -n "$items" ] || return 0
  say "→ post_clone"
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    local cmd="" req="" ife="" field
    cmd="$(trim "${item%%|*}")"
    local rest="${item#*|}"
    if [ "$rest" != "$item" ]; then
      while [ -n "$rest" ]; do
        field="$(trim "${rest%%|*}")"
        case "$field" in
          requires=*)  req="${field#requires=}" ;;
          if_exists=*) ife="${field#if_exists=}" ;;
        esac
        [ "${rest#*|}" = "$rest" ] && break
        rest="${rest#*|}"
      done
    fi
    if [ -n "$req" ] && ! have "$req"; then
      say "  • '$cmd' pulado — '$req' não está no PATH"; continue
    fi
    local n=0
    for d in "$WORKSPACE"/*/; do
      [ -d "$d/.git" ] || continue
      [ -n "$ife" ] && [ ! -e "$d/$ife" ] && continue
      if [ "$DRY" -eq 1 ]; then say "    [dry-run] (cd $d && $cmd)"; n=$((n+1)); continue; fi
      if ( cd "$d" && eval "$cmd" >/dev/null 2>&1 ); then n=$((n+1)); fi
    done
    say "  ✓ '$cmd' em $n repo(s)"
    POST_RESULT="$POST_RESULT\n  $cmd: $n repo(s)"
  done <<< "$items"
}
[ "$DO_POST" -eq 1 ] && [ "$DO_CLONE" -eq 1 ] && run_post_clone

# ── 7. projeção final ────────────────────────────────────────────────────────
# Roda por último de propósito: as etapas acima mexem nas FONTES (catalog/, mcp/),
# e é o sync que transforma isso no que os CLIs leem. Sem ele, uma skill recém
# importada existiria em catalog/skills sem aparecer em .claude/skills.
project_all() {
  if [ ! -x "$ROOT/bin/harness" ]; then
    say "→ projeção: bin/harness ausente — pulando"; SUMMARY_SYNC="bin/harness ausente"; return 0
  fi
  if [ "$DRY" -eq 1 ]; then say "    [dry-run] ./bin/harness sync"; SUMMARY_SYNC="dry-run"; return 0; fi
  say "→ projeção final (harness sync)"
  local out
  if out="$("$ROOT/bin/harness" sync 2>&1)"; then
    echo "$out" | sed 's/^/  /'
    SUMMARY_SYNC="ok"
  else
    echo "$out" | sed 's/^/  /'
    say "  ✗ sync falhou"; SUMMARY_SYNC="falhou"; FAILURES="$FAILURES\n  harness sync"
  fi
}
[ "$DO_SYNC" -eq 1 ] && project_all

# ── resumo ───────────────────────────────────────────────────────────────────
say ""
say "── resumo ─────────────────────────────────────────"
say "  plugins:  $SUMMARY_PLUGINS"
say "  skills git: $SUMMARY_VENDOR"
say "  skills npx: $SUMMARY_SKILLS"
say "  mcp:      $SUMMARY_MCP"
say "  projeção: $SUMMARY_SYNC"
if [ "$DO_CLONE" -eq 1 ]; then
  say "  repos:    $DECLARED declarado(s) — $CLONED clonado(s), $UPDATED atualizado(s), $EXISTING inalterado(s), $FAILED com problema"
fi
[ -n "$POST_RESULT" ] && printf "  post_clone:%b\n" "$POST_RESULT"
if [ -n "$FAILURES" ]; then
  printf "\n  ⚠ pendências:%b\n" "$FAILURES"
fi
say ""
say "workspace: $WORKSPACE"
if [ "$DO_MCP" -eq 1 ] && [ -f "$ROOT/.mcp.json" ]; then
  say "MCP e plugins só entram numa sessão que começa DEPOIS deste script — reinicie o Claude Code (ou rode /mcp) se ele já estava aberto."
  say ""
  say "As skills importadas ficam no CATÁLOGO (banco de reservas). Só as listadas em"
  say "active_skills viram titulares em .claude/skills e custam contexto:"
  say "  ./bin/harness skills                elenco atual"
  say "  ./bin/harness activate <skill>…     promove do banco pro time"
  say ""
  say "Na primeira abertura deste diretório o Claude Code pede para confiar na pasta; até"
  say "aceitar, os servers do .mcp.json ficam pendentes. É decisão por máquina — nenhum"
  say "arquivo do repo pula esse passo, e é isso que impede um repo clonado de auto-aprovar"
  say "os próprios MCP. Confira com: ./bin/harness doctor"
fi
