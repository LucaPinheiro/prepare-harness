# Repositórios da workspace

Registro canônico dos repositórios que este harness clona em `workspace/`.
A skill [`prepare-harness`](../catalog/skills/prepare-harness/SKILL.md) lê este
arquivo, extrai as URLs git das tabelas abaixo e clona cada repo em
`workspace/<nome-do-repo>` — pulando os já clonados e dando `pull --ff-only` nos
existentes. Os clones são independentes (branch, CI e histórico próprios) e **não
são versionados** aqui; veja o `.gitignore`.

## Formato

Uma linha de tabela por repositório:

```
| `nome-do-repo` | O que este serviço faz, em uma linha. | https://host/org/nome-do-repo |
```

Regras de extração — valem para qualquer host git (GitHub, GitLab, Bitbucket,
self-hosted), em HTTPS ou SSH (`git@host:org/repo.git`):

- Bloco de código e comentário HTML são ignorados por inteiro — é assim que este
  arquivo documenta o próprio formato sem que o exemplo acima vire um clone.
- Só entram URLs em **linhas de tabela ou de lista** (`|`, `-`, `*`). Título,
  prosa e blockquote são ignorados — é por isso que este parágrafo pode citar um
  formato de URL sem virar clone.
- Bloco dentro de comentário HTML é ignorado: comente um repo para desativá-lo
  temporariamente sem apagar a linha.
- A URL precisa ser `host/org/repo` (dois segmentos). Link de documentação com
  mais segmentos não vira clone por engano.
- Sobrando ruído, restrinja com `repo_filter` no `harness.config.yaml`.

Agrupe em quantas seções fizerem sentido (serviços, front-end, infra, libs…) — o
título da seção é só organização para humanos.

## Serviços

| Nome | Descrição | URL |
|------|-----------|-----|

## Front-end

| Nome | Descrição | URL |
|------|-----------|-----|

## Infraestrutura

| Nome | Descrição | URL |
|------|-----------|-----|
