---
name: prepare-harness
description: Monta e prepara um harness de agente genérico para clone-and-go — cria o esqueleto (harness.config.yaml, bin/harness, catalog/, mcp/, workspace/) quando ele não existe e, em seguida, instala plugins do Claude Code (oh-my-claudecode já configurado), importa bibliotecas de skills de repos git para catalog/skills, projeta o MCP project-scope (./.mcp.json, com playwright e context7 já ligados) e clona todos os repos declarados no registry (qualquer host git). Idempotente. Use SEMPRE que a conversa envolver preparar/configurar/bootar um harness, primeiro setup ou onboarding de um repo de agentes, criar a estrutura de um harness novo, faltar repo na workspace, ou depois de adicionar uma entrada no registry de repositórios — mesmo que a pessoa não use a palavra "harness" e só diga algo como "deixa esse projeto pronto pros agentes" ou "clona os repos do time".
allowed-tools: Read, Grep, Glob, Bash
triggers:
  user: ["/prepare-harness", "/preparar-harness", "/scaffold-harness"]
  model:
    - "preparar o harness"
    - "primeiro setup do harness"
    - "criar um harness do zero"
    - "clonar os repos da workspace"
    - "faltam repos na workspace"
    - "deixar o projeto pronto pros agentes"
---

# prepare-harness

Esqueleto genérico de harness + preparo idempotente. Nada aqui é específico de
uma organização: tudo que varia mora em arquivos de configuração marcados com
`TODO`, que você preenche uma vez.

## Quando usar

- **Harness novo**: um diretório vazio (ou um projeto que ainda não é harness) que
  precisa da estrutura — `scaffold` cria, você preenche, `prepare` executa.
- **Onboarding**: alguém acabou de clonar o harness do time e precisa da workspace
  montada e dos plugins/MCP no lugar.
- **Manutenção**: entrou repo novo no registry, ou algum repo esperado sumiu de
  `workspace/`.

Rodar de novo é seguro e barato — todas as etapas são idempotentes.

## O que faz

**Fase 1 — scaffold** (só quando `harness.config.yaml` não existe):

| Cria | Papel |
|------|-------|
| `harness.config.yaml` | Perfil: CLIs, workspace, registry, skills/plugins, `post_clone`. **Fonte da verdade.** |
| `bin/harness` | `sync` (projeta pros CLIs) e `doctor` (diagnostica, lista TODOs pendentes). |
| `bin/render_mcp.py`, `bin/render_plugins.py` | Projeção `mcp/servers.json` → `.mcp.json` e catálogo → `.claude/settings.json`. |
| `catalog/plugins/plugins.json` | Marketplaces + plugins. Já vem com **`oh-my-claudecode@omc`** habilitado. |
| `catalog/skills/prepare-harness/` | Cópia desta skill, pro harness nascer autossuficiente. É a única titular no início. |
| `mcp/servers.json` | MCP servers. Se o projeto já tinha `.mcp.json`, ele é **importado** em vez de sobrescrito. |
| `workspace/repositories.md` | Registry dos repos: vem no formato certo e **vazio**, só as tabelas para preencher. |
| `AGENTS.md` | Contrato compartilhado no padrão agents.md, já preenchido com o que é de harness (fonte canônica × projeção, precedência do AGENTS.md mais próximo, verificação, segurança) e com TODOs só para o que é do domínio. |
| bloco no `.gitignore` | Projeções, segredos, clones e o vendor de skills. |

**Fase 2 — prepare** (sempre):

1. Acha a raiz do harness subindo a partir do diretório atual (funciona de dentro de um clone).
2. (Opcional, `--sync`) roda `./bin/harness sync`.
3. **Plugins do Claude Code** declarados em `catalog/plugins/plugins.json`, via `claude plugin`
   (adiciona o marketplace, depois `install --yes <plugin>@<marketplace>`). Pula os já
   instalados, desabilita os `enabled:false`. Sem o `claude` no PATH a etapa é pulada — o
   `.claude/settings.json` projetado assume no próximo start.
4. **Skills de repos git** (`skill_repos`): para cada repo declarado, `git clone --depth 1`
   num staging (`skills_vendor_dir`), copia **toda pasta com `SKILL.md`** para
   `catalog/skills/<nome>` — o **catálogo**, que é o banco de reservas do harness e é
   versionado com ele — e **apaga o clone em seguida** (o staging some junto se ficar vazio).
   O que fica no harness é o catálogo, não o checkout; `--keep-vendor` preserva o clone só
   pra debug. O nome vem do `name:` do frontmatter, não da pasta. Cada cópia recebe um
   `.vendored-from`: é ele que autoriza a atualização no próximo run e protege as skills
   escritas pelo time. **Importar não ativa** — quem escala é o engenheiro, em
   `active_skills` (`./bin/harness activate <skill>`). O padrão do template é
   `https://github.com/LucaPinheiro/personal-skills` — basta ter `git` no PATH.
5. **Pacotes de skills do ecossistema público** de `skills_sources`, via
   `npx skills add <repo> --project --all`.
6. **MCP project-scope**: gera `./.mcp.json` a partir dos servers `enabled` e grava
   `enabledMcpjsonServers` no `.claude/settings.json` (declara quais servers o time
   aprovou). O settings.json é **mesclado**, não sobrescrito. Isso **não** dispensa o
   diálogo de confiança da pasta na primeira abertura — ver armadilhas.
7. **Clones**: extrai toda URL git do registry e clona em `workspace/<repo>`; nos já clonados
   dá `git pull --ff-only`. Repo privado no GitHub usa `gh` quando autenticado.
8. **`post_clone`**: roda os comandos declarados dentro de cada repo da workspace
   (`graphify hook install`, `uv sync`, `pnpm install`… — o que o time precisar).

## Como executar

Os scripts fazem o trabalho mecânico; **preencher os `TODO` é trabalho seu**, e é
o que transforma isto num fluxo de uma chamada só. O esqueleto sem conteúdo não
clona nada (os placeholders são ignorados de propósito), então parar em "agora
preencha os TODO" seria entregar meio serviço.

**Harness existente** — nada a decidir, só executar, da raiz ou de qualquer subdiretório:

```bash
bash catalog/skills/prepare-harness/scripts/prepare-harness.sh
```

**Harness novo** — quatro passos, sem devolver a lição de casa pra pessoa (só o
último depende de uma resposta dela):

```bash
# 1. esqueleto
bash <caminho-da-skill>/scripts/scaffold-harness.sh .
```

**2. preencha os arquivos** com o Edit/Write, na ordem abaixo. Tire os fatos, nesta
prioridade: (a) o que a pessoa já disse na conversa; (b) o próprio repo — `git
remote -v`, README, `.mcp.json` e `.claude/settings.json` que já existam;
(c) uma pergunta objetiva, só para o que sobrar. O resto tem default sensato —
deixe `mcp/servers.json` e `catalog/plugins/plugins.json` com tudo
`enabled: false` se ninguém pediu nada, porque um MCP quebrado no `.mcp.json`
atrapalha mais que um MCP ausente.

**O registry é a exceção e não se preenche aqui.** Deixe
`workspace/repositories.md` com as tabelas vazias, como o scaffold entregou, e
siga. Os repos entram no passo 4, no fim, e só pela mão da pessoa.

| Arquivo | Preencha com |
|---|---|
| `harness.config.yaml` | `name`, `tools`, `skill_repos`, `post_clone` (o `repo_filter` só quando ela já tiver dado os links) |
| `workspace/repositories.md` | **nada agora** — fica vazio até o passo 4 |
| `mcp/servers.json` | só o que a pessoa usa de fato; o resto `enabled: false` |
| `catalog/plugins/plugins.json` | o `oh-my-claudecode@omc` já vem ligado; apague a entrada `TODO-` se não for usar |
| `AGENTS.md` | só a seção **TODO** do fim (contexto de negócio, convenções, specs, PR); o resto do arquivo já é o padrão de harness |

```bash
# 3. conferir e executar
./bin/harness doctor          # lista o que ainda tem TODO
bash catalog/skills/prepare-harness/scripts/prepare-harness.sh
```

**4. no fim, pergunte quais repos entram** — e pergunte de verdade, sem lista pronta.

> **Nunca sugira repos.** Não rode `gh repo list`, `gh api user/repos`,
> `gh org list` nem equivalente para montar opções; não infira a org do e-mail da
> pessoa, de outras skills carregadas ou de qualquer sinal de contexto; e não
> ofereça conjuntos prontos — "stack agêntica", "tudo de 2026", "os 5 mais
> recentes" e afins estão fora. Enumerar a conta de alguém troca uma decisão dela
> por uma curadoria sua, e a curadoria erra: repo arquivado, repo de cliente, fork
> de terceiro — todos viram clone em `workspace/` sem ninguém ter pedido.

Faça **uma** pergunta aberta e espere a resposta:

> Quais repositórios devem entrar no registry deste harness?
> Me manda os links (um por linha). Se não for nenhum agora, tudo bem — dá pra
> adicionar depois a qualquer momento.

"Nenhum" é resposta completa e final: harness com registry vazio funciona, e o
`prepare-harness.sh` roda sem clonar nada. Para cada link recebido, grave uma
linha de tabela em `workspace/repositories.md` e rode o `prepare-harness.sh` de
novo — o clone é a única etapa que muda.

Buscar a descrição de um repo que a pessoa **já escolheu** é preencher, não
sugerir: `gh repo view <owner/repo> --json description` resolve a coluna do meio.

Flags do `prepare-harness.sh`: `--scaffold`, `--no-sync`, `--dry-run`, `--list`, `--no-pull`,
`--no-plugins`, `--no-skill-repos`, `--keep-vendor`, `--no-skills`, `--no-mcp`, `--no-clone`,
`--no-post-clone`.
Do `scaffold-harness.sh`: `--force`, `--no-skill-copy`.

Depois do setup, a escalação é sua: `./bin/harness skills` mostra titulares × banco,
`activate`/`deactivate` promovem e devolvem.

## O bootstrap não se atualiza sozinho

`prepare-harness` é a skill que levanta o harness, então ela é a única que precisa
existir **antes** de qualquer import rodar. Quem a entrega é o `scaffold`, que a
copia para `catalog/skills/prepare-harness` **sem** marcador `.vendored-from` — ou
seja, como skill do time, que o import é proibido de tocar.

**Não coloque o repo desta skill em `skill_repos`.** Parece tentador (é um repo
git com skills dentro, como qualquer outro), mas cria um ciclo: o import
sobrescreveria, no meio da execução, o próprio script que está executando. Na
prática o run sobrevive — o `rm` desvincula o arquivo e o shell continua lendo o
inode antigo — mas isso é acidente do Unix, não desenho, e qualquer edição local
na pasta some sem aviso.

O script se protege sozinho: ao encontrar no catálogo a skill da qual ele próprio
faz parte, pula com `~ <skill> — é a skill que está rodando este script; não me
sobrescrevo`. Para atualizar o bootstrap de verdade, rode o `scaffold-harness.sh
--force` a partir do repo de origem — ato deliberado, que é o certo para a peça
que levanta todas as outras.

Comece por `--dry-run` quando o harness for de outra pessoa: ele imprime cada
clone, plugin e comando `post_clone` que seria executado, sem tocar em nada.

## O que preencher

Tudo que precisa de mão está marcado com `TODO` — `./bin/harness doctor` lista os
arquivos pendentes. O essencial:

- `harness.config.yaml` → `name`, `tools`, `repo_filter`, `skill_repos` (a biblioteca de
  skills do time), `post_clone`.
- `workspace/repositories.md` → a tabela de repos, montada **só com os links que a
  pessoa mandar** (ver passo 4). Aceita qualquer host git (GitHub, GitLab, Bitbucket,
  self-hosted), HTTPS ou SSH. Só casa URLs `host/owner/repo`, então link de
  documentação com mais segmentos não vira clone por engano. Se o registry citar
  links que não são repos, restrinja com `repo_filter`. Vazio é um estado válido:
  nada a clonar é diferente de setup incompleto.
- `mcp/servers.json` → `enabled: true/false` por server. Segredos ficam em `${VAR}`.
- `catalog/plugins/plugins.json` → o nome do marketplace precisa bater com o campo
  `name` do `marketplace.json` do repo de origem, não com o nome do repo.

## Pré-requisitos

`git` é o único requisito duro. O resto é best-effort — cada etapa avisa e segue:

| Binário | Necessário para | Sem ele |
|---------|-----------------|---------|
| `gh` autenticado | clonar repo **privado** do GitHub | cai em `git clone` (falha se privado) → peça `! gh auth login` |
| `claude` | instalar plugins | etapa pulada; o settings.json projetado assume no próximo start |
| `npx` (Node) | `skills_sources` | etapa pulada |
| `python3` | projeção de MCP/plugins | etapa pulada |

## Saída

Ao final, um resumo com: plugins habilitados/desabilitados/falhos, pacotes de skills
instalados, MCP servers que entraram no `.mcp.json`, contagem de repos
(declarados / clonados / atualizados / inalterados / com problema), quantos repos
receberam cada comando `post_clone`, e uma seção **pendências** com o que falhou e
por quê (repo privado sem acesso, remote divergente, plugin com nome inválido…).

Repasse esse resumo para a pessoa e, se houver pendência de autenticação, sugira o
comando exato — `! gh auth login` roda direto na sessão.

## Fallback manual

Se os scripts não puderem rodar:

```bash
# repos declarados no registry
grep -oE '(https?://[^ )|]+|git@[^ )|]+)' workspace/repositories.md | sed 's#\.git$##' | sort -u
# clone
git clone <url> workspace/<nome>          # ou: gh repo clone <owner>/<repo> workspace/<nome>
# skills externos e plugins
npx --yes skills add <repo> --project --all
claude plugin marketplace add <owner/repo> && claude plugin install --yes <plugin>@<marketplace>
```

## Notas de armadilha

Leia `references/gotchas.md` antes de debugar "o MCP não apareceu", "o plugin não
carregou" ou "o skills add travou" — as três causas mais comuns estão lá, com o
motivo. O resumo:

- `.mcp.json` **na raiz** é o único lugar de MCP project-scope; `.claude/.mcp.json` não existe.
- MCP e plugins entram numa sessão que **começa depois** do script — reinicie ou rode `/mcp`.
- Nenhum arquivo versionado pré-aprova MCP: a confiança da pasta é aceita **uma vez por
  máquina**, no diálogo interativo. `./bin/harness doctor` diz se já foi.
- `skills add` sem `--all` é interativo e trava em não-TTY.
