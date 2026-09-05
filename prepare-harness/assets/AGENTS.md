# TODO-nome-do-harness

Contrato compartilhado deste harness. `CLAUDE.md` é um symlink para cá, então
Claude Code, Devin CLI e qualquer agente compatível com AGENTS.md leem o mesmo
arquivo.

> **Este arquivo entra em todo contexto de todo agente, em toda sessão.** Ele é um
> índice, não um manual: aponte para onde a informação mora em vez de copiá-la.
> Se uma seção passar de uma tela, ela provavelmente pertence a `specs/`, a uma
> skill ou ao AGENTS.md do repo específico.

## O que é este repositório

Um **harness**: o ambiente de trabalho dos agentes deste time. Ele não contém o
produto — contém o *contexto* (este arquivo, specs, decisões), as *capacidades*
(skills, plugins, sub-agentes), as *ferramentas* (MCP) e os *clones* dos
repositórios onde o produto de fato vive.

A consequência prática: você abre **o harness**, não os repos soltos. Uma tarefa
que atravessa três serviços acontece numa sessão só, com o contexto certo já
carregado.

## Setup

```bash
bash catalog/skills/prepare-harness/scripts/prepare-harness.sh   # setup / onboarding
./bin/harness sync      # depois de mexer em catalog/, agents/, mcp/ ou no config
./bin/harness doctor    # quando algo não aparece no CLI
```

Tudo é idempotente: rodar de novo é a forma normal de consertar um ambiente
estranho, não um risco.

**MCP e plugins só valem para sessões que começam depois do setup.** Se algo não
apareceu, reinicie a sessão ou rode `/mcp` — não é bug, é ordem de carregamento.
Na primeira vez que alguém abre este diretório, o Claude Code pede para confiar na
pasta: até aceitar, os servers do `.mcp.json` ficam pendentes. É uma decisão por
máquina, que nenhum arquivo do repo pode substituir — `./bin/harness doctor` diz
em que estado ela está.

## Como trabalhar aqui

0. **Pergunta sobre código? Consulte o grafo primeiro.** Se o repo tiver
   `graphify-out/graph.json`, use o Graphify **antes** de `grep`/`find` ou de abrir
   arquivos: ele devolve um subgrafo escopado em vez de despejar código no contexto
   (ordem de ~70× menos tokens num repo grande).
   ```bash
   graphify query "o que conecta auth ao banco?"   # relação entre conceitos
   graphify path "UserService" "DatabasePool"      # caminho entre dois nós
   graphify explain "RateLimiter"                  # vizinhança de um nó
   graphify update .                               # depois de mexer no código (AST, sem custo de API)
   ```
   Sem `graphify-out/`, siga com busca normal. Sem o binário:
   `uv tool install graphifyy` — o pacote é `graphifyy`, o comando é `graphify`.
   Ao citar uma relação do grafo, confira a `confidence` da aresta: `EXTRACTED` é
   observação direta, `AMBIGUOUS` é hipótese a verificar no fonte.
1. **Comece pelo contexto que já existe.** Uma skill relevante, o AGENTS.md do repo
   que você vai editar, a spec. Improvisar procedimento quando existe um escrito é
   o desperdício mais caro deste ambiente.
2. **Uma tarefa que atravessa repos é uma tarefa só.** Não abra sessão por repo:
   a workspace inteira está aqui justamente para isso.
3. **Mudou fonte canônica? Rode `harness sync`.** Editar a projeção não sobrevive.
4. **Verifique antes de afirmar** (ver abaixo) — inclusive UI, com o MCP do
   Playwright.
5. **Ação difícil de reverter ou que sai deste ambiente** (deploy, migração,
   publicar pacote, abrir PR) pede confirmação de uma pessoa antes.

## A regra que explica o layout: fonte canônica ≠ projeção

Cada coisa tem **um** lugar de verdade. O que os CLIs leem é gerado a partir dele
por `harness sync`. Editar a projeção funciona até o próximo sync e depois some —
por isso a edição vai sempre na fonte.

| Fonte canônica (edite aqui) | Projeção (gerada, não edite) |
|---|---|
| `harness.config.yaml` — perfil: CLIs, skills/agentes ativos, workspace | — |
| `catalog/skills/<nome>/SKILL.md` | `.claude/skills/*`, `.devin/skills/*` |
| `catalog/plugins/plugins.json` | `.claude/settings.json` (marketplaces + plugins) |
| `agents/<nome>/AGENT.md` | `.claude/agents/*.md` |
| `mcp/servers.json` | `.mcp.json`, `.devin/config.json` |
| `AGENTS.md` | `CLAUDE.md` (symlink) |
| `workspace/repositories.md` | `workspace/<repo>/` (clones) |
| `skill_repos` (no config) | `catalog/skills/<nome>` importadas + `catalog/skills-vendor/` (staging, não versionado) |

Exceção: `.claude/settings.json` é **mesclado**, não sobrescrito — configuração
manual (permissions, hooks, env) sobrevive ao sync.

## Trabalhando nos repos da workspace

Os clones em `workspace/<repo>/` são repositórios independentes: branch, CI e
histórico próprios. Duas regras:

1. **O AGENTS.md mais próximo vence.** Ao editar `workspace/<repo>/src/x`, o
   AGENTS.md daquele repo manda no que for específico dele (stack, testes,
   convenções). Este arquivo cobre o que é do harness.
2. **Commit e PR acontecem dentro do repo**, nunca aqui. O harness não versiona os
   clones.

## Capacidades: quem faz o quê

- **Skills** (`catalog/skills/`) — procedimento reutilizável que um agente segue.
  **Antes de improvisar um procedimento, veja se já existe uma skill para ele.**
  Se você se pegar repetindo a mesma instrução em prompts, isso é uma skill
  faltando, não um prompt melhor.
- **Plugins** (`catalog/plugins/plugins.json`) — capacidades empacotadas de
  terceiros (orquestração multi-agente, agentes especializados).
- **Sub-agentes** (`agents/`) — papéis com contexto e ferramentas próprios, para
  trabalho que merece uma janela de contexto separada.
- **MCP** (`mcp/servers.json`) — acesso a sistemas externos.

### A biblioteca de skills: elenco e escalação

`catalog/skills/` é o **elenco inteiro** — o banco de reservas. Estar no catálogo
não custa nada e não torna a skill visível. Só o que está em `active_skills` vira
**titular**: o `sync` linka em `.claude/skills` e o agente passa a enxergar.

A escalação é decisão de engenharia, não default, porque **cada titular carrega
nome e descrição em toda sessão** — contexto pago mesmo sem ser usado. Elenco
grande é ótimo; time inteiro em campo, não.

```bash
./bin/harness skills                # quem é titular, quem está no banco
./bin/harness activate graphify     # promove (e projeta)
./bin/harness deactivate aws-cli    # volta pro banco, continua no catálogo
```

Precisa de uma skill que está no banco? Promova, use, e devolva se não for virar
rotina. Nada se perde: sair do time não apaga nada do catálogo.

Duas origens, e a diferença importa na hora de editar:

| | Origem | Editar onde |
|---|---|---|
| **Importada** | tem `.vendored-from` dentro; veio de um repo de `skill_repos` | **no repo de origem** — o próximo `prepare-harness` sobrescreve a cópia local |
| **Do time** | sem `.vendored-from` | aqui mesmo; é fonte canônica |

Para adotar uma skill importada como sua, apague o `.vendored-from` dela: o import
passa a respeitar o diretório.

### MCP disponíveis

- **playwright** — automação de browser. Use para verificar UI de verdade
  (navegar, clicar, preencher, screenshot) em vez de afirmar que a tela funciona.
  Sobe sob demanda via `npx`; precisa de Node.
- **context7** — documentação atualizada de bibliotecas. Consulte **antes** de
  sugerir API de biblioteca: o conhecimento do modelo tem data de corte, a doc não.

Server que exige credencial fica `enabled: false` até o token existir — um MCP
quebrado atrapalha mais que um MCP ausente.

## Verificação

**Evidência antes de afirmação.** Não declare algo pronto, corrigido ou funcionando
sem ter rodado a verificação e visto a saída. Se um passo foi pulado ou um teste
falhou, diga isso explicitamente — um relatório honesto de meio caminho vale mais
que um "pronto" que não se sustenta.

Para bug: reproduza antes de corrigir e ataque a causa raiz, não o sintoma.

<!-- TODO: comandos de verificação do time, se houver algo no nível do harness.
     Os comandos de build/teste de cada serviço pertencem ao AGENTS.md do repo. -->

## Segurança

- Segredos **nunca** no repositório. MCP usa `${VAR}` do ambiente; overrides locais
  vão em `*.local.json` (fora do versionamento).
- Antes de rodar comando que altera ambiente compartilhado (deploy, migração,
  recurso de cloud), confirme com uma pessoa. Autorização em um contexto não vale
  para o próximo.

## TODO — preencha antes de considerar este harness pronto

- [ ] **Contexto de negócio**: o que o time constrói, quais domínios existem, quem
      consome. 5–10 linhas ou um ponteiro para onde isso está escrito.
- [ ] **Convenções**: stack, padrões de código, o que revisar antes de abrir PR.
- [ ] **Onde ficam specs e decisões**: `specs/`, vault, Notion, Linear…
- [ ] **Commit e PR**: formato de mensagem, política de branch.
