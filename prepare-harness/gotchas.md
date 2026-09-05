# Armadilhas conhecidas (MCP, plugins, skills, clones)

Cada item aqui já custou uma sessão de debug para alguém. Leia antes de concluir
que "o script não funcionou".

## MCP

**Onde o Claude Code lê MCP de projeto.** Só o `./.mcp.json` na **raiz** do repo.
Não existe `.claude/.mcp.json` — arquivo com esse nome é ignorado em silêncio, que
é o pior modo de falha possível.

**Nenhum arquivo versionado pré-aprova MCP.** `enabledMcpjsonServers` no
`.claude/settings.json` declara quais servers o time aprovou, mas o que libera o
MCP project-scope é a **confiança da pasta**, aceita uma vez por máquina no
diálogo interativo do Claude Code. Medido em 2026-08-26, num harness recém-clonado:
com `enabledMcpjsonServers` **e** `enableAllProjectMcpServers` escritos no
settings.json, `claude mcp list` seguia mostrando `context7` como *Pending
approval*; virando `hasTrustDialogAccepted` para `true` no `~/.claude.json` o mesmo
server passou a *Connected*, e voltando para `false` voltou a pendente.

Isso é proteção, não bug: se um arquivo do repo pudesse se auto-aprovar, bastaria
clonar um projeto hostil para ele subir os MCP servers dele na sua máquina. Não
tente contornar escrevendo em `~/.claude.json` por script — abra o diretório uma
vez e aceite. `./bin/harness doctor` mostra o estado da confiança.

**A sessão lê no início.** Rodar a skill com o Claude Code já aberto não faz o MCP
aparecer: reinicie a sessão, ou rode `/mcp` para reconectar. O mesmo vale para
plugins recém-instalados.

**`auth: oauth`** (Linear, Figma e afins) pede autenticação interativa na primeira
conexão — `/mcp` → *authenticate*. Nenhum script resolve isso por você.

**`auth: pat`** (stdio com token em env) é traiçoeiro: sem a variável exportada o
processo **sobe normalmente** e só as chamadas falham. Se o token ainda não existe,
deixe `enabled: false` em vez de deixar o server quebrado no `.mcp.json`.

**Segredos.** `mcp/servers.json` é versionado. Use `${VAR}` e exporte no ambiente,
ou mantenha um `*.local.json` fora do git. Token literal ali vaza no primeiro push.

**Redundância.** Um MCP que você já tem em escopo de usuário (Context7, por
exemplo) não precisa entrar no escopo de projeto — duas cópias do mesmo server só
gastam contexto.

## Plugins do Claude Code

**O nome do marketplace não é o nome do repo.** Em `plugins.json`, a chave de
`plugins` é `<plugin>@<marketplace>`, e `<marketplace>` precisa bater com o campo
`name` do `.claude-plugin/marketplace.json` do repo de origem. Ex.:
`Yeachan-Heo/oh-my-claudecode` declara `name: omc`, então a chave é
`oh-my-claudecode@omc`. Errar isso dá "falha ao instalar" sem explicar o motivo.

**`--yes` é obrigatório fora de TTY.** `claude plugin install` confirma o comando
declarado pelo marketplace antes de instalar; sem `-y/--yes` num script ele não
completa.

**Escopo.** O padrão do CLI é `--scope user` (instala pro usuário). `--scope
project` grava a instalação no projeto — útil se o time quer o plugin travado no
repo, mas aí a projeção do `settings.json` e a instalação passam a ter duas fontes.
Escolha uma.

**Desligar de verdade.** `enabled: false` no catálogo faz o script rodar
`claude plugin disable` **e** projetar `false` no `settings.json`. Só apagar a
entrada do JSON não desinstala nada.

## Skills vindas de repos git (`skill_repos`)

**O vendor não é versionado.** `skills_vendor_dir` (padrão `catalog/skills-vendor/`)
entra no `.gitignore`: a fonte é o repo de origem, e versionar duas cópias da mesma
skill só gera conflito. Quem clonar o harness recebe as skills rodando
`prepare-harness.sh`, não pelo git deste repo.

**Atualizar é `git pull`.** As entradas em `.claude/skills/` são **symlinks** para
dentro do vendor, então atualizar o clone atualiza as skills — nenhum passo de
"reinstalar". Rodar a skill de novo já faz o pull.

**Colisão de nome não sobrescreve.** Se `.claude/skills/<nome>` já existe — como
link para outro lugar, como diretório real, ou como skill do próprio
`catalog/skills/` — a vendored é ignorada com aviso. A skill do harness vence
porque ela é a que o time escreveu para aquele contexto.

**Sobreposição conceitual com plugins.** Plugins expõem suas skills namespaced
(`oh-my-claudecode:brainstorming`), então não há colisão de nome com uma
`brainstorming` vendored — mas há duas versões do mesmo procedimento disponíveis ao
mesmo tempo. Se isso confundir o agente, desligue um dos lados em vez de manter os
dois "por garantia".

**Qualquer pasta com SKILL.md vira skill.** A varredura é recursiva e independe da
estrutura de categorias do repo (`coding/`, `superpowers/`…). Um `SKILL.md`
aninhado dentro de outra skill é ignorado — o pai vence.

**O nome vem do frontmatter, não da pasta.** Quando `name:` e o diretório divergem,
vale o `name:` — é ele que o CLI usa para resolver a invocação. A skill do Graphify
é o caso típico: mora em `operational/graphifyy/` (nome do pacote PyPI) e se chama
`graphify` (nome do comando). Importar pelo nome da pasta criaria um `/graphifyy`
que ninguém digita. O import avisa quando renomeia.

**Graphify: cuidado com `graphify hook install` no `post_clone`.** A skill recomenda
os hooks, mas medição no harness da Dupli (2026-08-12) mostrou o `post-commit` do
Graphify reconstruindo o grafo em background e **encolhendo** o `graph.json` em
silêncio (7674 → 7237 nós logo após um commit de documentação), além de deixar
`merge.graphify.driver` vazio apesar de anunciar o merge driver. Se for ligar,
prefira rodar `graphify update .` explicitamente e configurar o merge driver à mão.

## Pacotes de skills (`npx skills add`)

**É interativo por padrão.** Sem flags, o CLI pergunta quais skills e quais agentes
receber. Num script isso trava (ou falha em silêncio se a saída estiver
redirecionada). `--all` é o atalho de `--skill '*' --agent '*' -y`.

**Escopo.** `--project` grava `skills-lock.json` no repo (bom para clone-and-go, o
time inteiro recebe as mesmas versões); `--global` instala em `~/.claude`. Depois de
ter o lock, `npx skills experimental_install` restaura as versões travadas.

**Atualização.** `skills add` num repo já instalado atualiza. Para atualizar tudo de
uma vez: `npx skills update -y -p`.

## Clones da workspace

**Repo privado do GitHub precisa de `gh` autenticado.** O `git clone` puro falha com
uma mensagem de "repository not found" que parece erro de digitação. Se `gh auth
status` não estiver OK, peça: `! gh auth login`.

**Colisão de nome.** O destino é `workspace/<nome-do-repo>`. Dois repos com o mesmo
nome em orgs diferentes disputam o mesmo diretório — por isso o script compara o
`origin` antes de dar pull e, se divergir, avisa e **não toca** no diretório em vez
de misturar os dois.

**`pull --ff-only` falha de propósito.** Branch divergente, sem upstream ou offline
não são erro do harness: o script reporta "pull pulado" e segue. Resolver o estado
do clone é decisão de quem está trabalhando nele.

**URLs que não são repositórios.** A extração só casa `host/owner/repo` — um link de
documentação com mais segmentos (`host/a/b/c`) é ignorado. Ainda assim, se o
registry misturar muitos links, use `repo_filter` no `harness.config.yaml`.

## Projeções

**Não edite `.claude/`, `.devin/` ou `.mcp.json` à mão.** São gerados por
`harness sync` a partir de `catalog/`, `agents/` e `mcp/`. Edição manual se perde no
próximo sync — a exceção é o `.claude/settings.json`, que é **mesclado**: chaves que
não são do harness (permissions, hooks, env, model) sobrevivem.

**`CLAUDE.md` é symlink pro `AGENTS.md`.** Se já existir um `CLAUDE.md` de verdade no
projeto, o `sync` avisa e não sobrescreve — junte os dois à mão e apague o arquivo
real quando quiser o symlink.
