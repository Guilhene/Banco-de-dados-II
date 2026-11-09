# Marco 2 — Views, Índices e Transações

**Banco de Dados II (CCO072) · IESB 2026/2 · Projeto Acadêmico**
Integrantes: _(preencher)_

Este diretório contém tudo o que o Marco 2 pede, construído sobre o esquema do Marco 1 (`Marco_01.sql`):

| Item do enunciado | Entrega | Arquivo |
|---|---|---|
| 3 views + 1 materialized view, com política de atualização justificada | `vw_historico_aluno`, `vw_ocupacao_turma`, `vw_carga_professor`, `mv_desempenho_curso` | `01_views.sql` |
| ≥ 4 índices, 1 parcial, com `EXPLAIN` antes/depois | 5 índices (1 parcial, 1 composto, 1 por expressão) | `02_indices.sql` |
| Anomalia de transação e duas correções, com comparação | overbooking de vagas; `FOR UPDATE` e `SERIALIZABLE` | `03_transacoes.sql`, `transacoes/` |
| Análise e resultados | relatório com evidências | `RELATORIO_Marco2.md` |

---

## Ordem de execução

Execute **nesta ordem**, sempre na base `matricula` (`localhost:5433`):

| Passo | Arquivo | O que faz | Observação |
|:-:|---|---|---|
| 1 | `Marco_01.sql` | cria as tabelas | apague a linha `CREATE DATABASE Projeto_universidade;` |
| 2 | `00_dados.sql` | **insere os dados de teste** (~50 mil alunos, ~250 mil matrículas) | só em banco **vazio**; rodar duas vezes dá erro de chave duplicada |
| 3 | `01_views.sql` | cria as 3 views e a materialized view | precisa do passo 1 |
| 4 | `02_indices.sql` | cria os índices e mostra o `EXPLAIN` antes/depois | precisa do passo 2; sem dados o índice não aparece no plano |
| 5 | `03_transacoes.sql` | anomalia e correções, com duas sessões | tem preparação própria, não depende do passo 2 |

Para recomeçar do zero: `docker compose down -v` → `docker compose up -d` → repetir a partir do passo 1.

---

## Estrutura

```
marco2/
├── 00_dados.sql               # dados sintéticos (~50 mil alunos, ~250 mil matrículas)
├── 01_views.sql               # views + materialized view + política de atualização
├── 02_indices.sql             # cria os índices e mostra o EXPLAIN antes/depois (SQL puro)
├── 03_transacoes.sql          # roteiro manual com duas sessões (A e B)
└── README_MARCO_02.md         # relatório completo
```

---

## Pré-requisito: ambiente

```bash
docker compose up -d
```

| Serviço | Endereço | Credenciais |
|---|---|---|
| PostgreSQL | `localhost:5433` (**5433**, não 5432) | usuário `bd2` · senha `bd2` · base `matricula` |
| pgAdmin | http://localhost:8080 | `admin@iesb.br` · `admin` |

Para recomeçar do zero (**apaga todos os dados do banco**): `docker compose down -v` e depois `docker compose up -d`.

---

## Como executar

### No DBeaver
- Abra o arquivo e use **Executar script (Alt+X)**; Ctrl+Enter executa só um comando.
- Os arquivos numerados são SQL puro. O DBeaver **não** entende comandos do `psql` (`\echo`, `\set`, `\o`, `\gset`); só `transacoes/sessao.sql` os usa, e ele é para rodar pelo terminal (psql).
- No `03_transacoes.sql`, o contrário: **um comando por vez** (Ctrl+Enter), em **duas abas com conexões separadas** (A e B), na ordem indicada nos comentários.

### No psql / terminal
```bash
export PGPASSWORD=bd2
P="psql -h localhost -p 5433 -U bd2 -d matricula -v ON_ERROR_STOP=1"
$P -f Marco_01.sql          # sem a linha CREATE DATABASE
$P -f marco2/00_dados.sql
$P -f marco2/01_views.sql
$P -f marco2/02_indices.sql

./marco2/transacoes/executar_demo.sh sem_protecao    # a anomalia
./marco2/transacoes/executar_demo.sh for_update      # correção 1
./marco2/transacoes/executar_demo.sh serializable    # correção 2
./marco2/transacoes/executar_carga.sh                # comparação sob carga (pgbench >= 15)
```
Sem `psql` instalado no computador, use o do contêiner:
`docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < arquivo.sql`

---

## Resumo dos resultados

### Views
A `mv_desempenho_curso` é atualizada **1 vez por dia, de madrugada**, com `REFRESH MATERIALIZED VIEW CONCURRENTLY`. A justificativa (indicadores gerenciais toleram defasagem; o cálculo é caro; recalcular a cada nota penalizaria as transações críticas; o `CONCURRENTLY` não bloqueia leitores) está em `RELATORIO_Marco2.md`, seção 1.

### Índices
| # | Índice | Antes → depois |
|---|---|---|
| 1 | `idx_matricula_aluno (id_aluno)` | 14,3 ms → 0,11 ms |
| 2 | `idx_matricula_turma_ativa (id_turma) WHERE status_matricula='ativa'` — **parcial** | 15,2 ms → 0,03 ms |
| 3 | `idx_aluno_curso_status (id_curso, status_aluno)` — composto | 4,0 ms → 0,39 ms |
| 4 | `idx_turma_professor (id_professor)` | 0,13 ms → 0,04 ms |
| 5 | `idx_aluno_nome_lower (lower(nome_aluno) text_pattern_ops)` — por expressão | 13,9 ms → 0,02 ms |

O índice parcial ocupa 488 kB, contra 1.616 kB do índice completo equivalente. Tempos de uma máquina de teste: o que vale é a proporção e o plano (`Seq Scan` → `Index/Bitmap Scan`). Detalhes e ressalvas na seção 2 do relatório.

### Transações
**Anomalia:** overbooking — duas transações conferem que há vaga, ambas inserem, e uma turma de 1 vaga fica com 2 matriculados.

| | Sem proteção | `FOR UPDATE` | `SERIALIZABLE` + retry |
|---|---|---|---|
| Vagas estouradas (800 tentativas, 200 vagas) | 15–17 | 0 | 0 |
| Vazão (tps) | 4.080–4.200 | 2.520–2.710 | 1.010–1.090 |
| Mecanismo | — | bloqueia quem chega depois | aborta (`40001`); a aplicação repete |

Recomendação: `FOR UPDATE` na linha da turma. Análise completa na seção 3 do relatório.

---

## Observações e limitações
- Os dados são **sintéticos** (`00_dados.sql`), criados só para dar volume. Os ids usados nas consultas de `EXPLAIN` (`id_aluno = 12345`, `id_turma = 500`...) foram escolhidos para esses dados.
- As views assumem os valores `status_matricula ∈ {ativa, concluida, trancada, cancelada}` e `situacao_nota ∈ {cursando, aprovado, reprovado}`, e média = média aritmética das provas já lançadas.
- Os testes foram executados em PostgreSQL 16; o ambiente da disciplina usa o 17. Nada depende da versão, exceto `pgbench --max-tries` (≥ 15).
- A pausa de 2 ms nos scripts do `pgbench` é artificial, para alargar a janela da corrida; num sistema real a anomalia seria mais rara, mas igualmente possível.
- Pendências sugeridas para o Marco 1: remover o `CREATE DATABASE`; `UNIQUE (id_aluno, id_turma)` em `tb_matricula`; `CHECK` nos campos de status.