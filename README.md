# prepare-harness

Skill do [Claude Code](https://claude.com/claude-code) que monta e prepara um
**harness de agente genérico** para clone-and-go.

Um harness aqui é um repo que carrega o contexto compartilhado de um time de
agentes: o registry dos repositórios em que se trabalha, o catálogo de skills, os
MCP servers aprovados, os plugins e o `AGENTS.md`. A skill cria essa estrutura
quando ela não existe e, em seguida, deixa tudo pronto para uso — de forma
idempotente, então rodar de novo é seguro e barato.

## O que ela faz

**Fase 1 — scaffold** (só quando `harness.config.yaml` não existe): cria o
esqueleto — `harness.config.yaml` (a fonte da verdade), `bin/harness` (`sync` e
`doctor`), `catalog/`, `mcp/`, `workspace/`, `AGENTS.md` e o bloco de
`.gitignore`. Tudo que varia por time vem marcado com `TODO`.

**Fase 2 — prepare** (sempre):

1. Instala os **plugins** do Claude Code declarados em `catalog/plugins/plugins.json`.
2. Importa **skills de repos git**: clona (`--depth 1`), copia toda pasta com
   `SKILL.md` para `catalog/skills/<nome>` e **descarta o checkout** — o que fica
   versionado é o catálogo, não a árvore git.
3. Instala pacotes de skills do ecossistema público (`npx skills add`).
4. Projeta o **MCP project-scope** em `./.mcp.json` e mescla o `.claude/settings.json`.
5. **Clona os repos** declarados no registry (qualquer host git) em `workspace/`.
6. Roda os comandos `post_clone` dentro de cada repo (`uv sync`, `pnpm install`…).

Importar uma skill **não a ativa**: `catalog/skills/` é o banco de reservas e
`active_skills` é a escalação, porque cada skill ativa custa contexto em toda
sessão. `./bin/harness activate <skill>` promove.

## Duas regras que a skill leva a sério

**O registry nunca é adivinhado.** A skill não enumera a conta de ninguém para
montar opções — nada de `gh repo list`, de org deduzida do e-mail, nem de
conjuntos prontos ("os 5 mais recentes"). No fim do setup ela faz uma pergunta
aberta, você manda os links, e ela registra exatamente esses. "Nenhum" é resposta
final: registry vazio é estado válido e o `prepare-harness.sh` sai com 0.

**O bootstrap não se atualiza sozinho.** Quem entrega a skill é o `scaffold`, que
a copia para `catalog/skills/` sem marcador de origem — o import é proibido de
tocar nela. Não coloque este repo em `skill_repos`: o script se recusa a
sobrescrever a skill de que ele próprio faz parte, e atualizar o bootstrap é um
`scaffold-harness.sh --force` deliberado.

## Instalação

```bash
git clone https://github.com/LucaPinheiro/prepare-harness.git
cp -R prepare-harness/prepare-harness ~/.claude/skills/
```

Ou, para deixá-la disponível só em um projeto, copie para `.claude/skills/` dele.

## Uso

```bash
# harness já existente — de qualquer subdiretório
bash <skill>/scripts/prepare-harness.sh

# harness novo
bash <skill>/scripts/scaffold-harness.sh .
# preencha os TODO, então:
./bin/harness doctor
bash catalog/skills/prepare-harness/scripts/prepare-harness.sh
```

Comece com `--dry-run` quando o harness for de outra pessoa: ele imprime cada
clone, plugin e comando que executaria, sem tocar em nada.

Flags principais: `--scaffold`, `--dry-run`, `--list`, `--keep-vendor`,
`--no-pull`, `--no-plugins`, `--no-skill-repos`, `--no-skills`, `--no-mcp`,
`--no-clone`, `--no-post-clone`.

## Pré-requisitos

`git` é o único requisito duro. `gh` (repos privados no GitHub), `claude`
(plugins), `npx` (pacotes de skills) e `python3` (projeção de MCP/plugins) são
best-effort: cada etapa avisa e segue.

## Documentação

- [`prepare-harness/SKILL.md`](prepare-harness/SKILL.md) — a skill completa.
- [`prepare-harness/references/gotchas.md`](prepare-harness/references/gotchas.md) —
  leia antes de debugar "o MCP não apareceu", "o plugin não carregou" ou "o
  `skills add` travou".
