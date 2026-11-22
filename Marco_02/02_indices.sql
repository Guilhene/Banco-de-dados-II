-- =====================================================================
-- Marco 2 — 02_indices.sql   (adaptado ao esquema atual do banco)
--
-- ORDEM DE EXECUÇÃO (sempre na mesma base):
--   1) instalar_tudo.sql  -> tabelas, segurança e dados (substitui o
--                            Marco_01.sql + 00_dados.sql antigos)
--   2) 01_views.sql       -> views + materialized view
--   3) 02_indices.sql     -> ESTE arquivo: índices + EXPLAIN antes/depois
--   4) 03_transacoes.sql  -> anomalia e correções (roteiro com 2 sessões)
-- =====================================================================
-- 5 índices (1 parcial, 1 composto, 1 por expressão), cada um com:
--   consulta-alvo -> EXPLAIN (ANALYZE, BUFFERS) ANTES -> CREATE INDEX
--   -> ANALYZE -> EXPLAIN (ANALYZE, BUFFERS) DEPOIS.
-- O script é reexecutável: começa apagando os índices (estado "antes") e
-- termina com todos eles criados.
--
-- O QUE MUDOU EM RELAÇÃO AO ESQUEMA ANTIGO:
--   * O esquema atual já tem índices que cobrem alguns casos:
--       - PK de tb_turma_matricula (id_turma, id_matricula) atende buscas por turma;
--       - UNIQUE (id_aluno, id_curso) de tb_matricula atende buscas por aluno.
--     Por isso o antigo "índice em tb_matricula(id_aluno)" seria REDUNDANTE;
--     o índice 1 agora é a FK id_matricula de tb_turma_matricula, que nenhum
--     índice existente cobre.
--   * status do aluno e curso agora ficam em tb_matricula (não em tb_aluno).
--   * Os índices idx_tm_matricula, idx_turma_professor e idx_matricula_aluno
--     já podem existir (foram criados por 01_alteracoes_banco.sql); este
--     script os recria de propósito para medir o "antes".
-- Cada EXPLAIN roda com ANALYZE; compare o plano (Seq Scan -> Index Scan)
-- e as proporções de tempo, não os milissegundos absolutos.
-- =====================================================================
SET search_path TO public;
SET max_parallel_workers_per_gather = 0;   -- plano sem paralelismo: comparação mais limpa

DROP INDEX IF EXISTS idx_tm_matricula;
DROP INDEX IF EXISTS idx_tm_turma_cursando;
DROP INDEX IF EXISTS idx_tm_turma_full;
DROP INDEX IF EXISTS idx_matricula_curso_status;
DROP INDEX IF EXISTS idx_turma_professor;
DROP INDEX IF EXISTS idx_aluno_nome_lower;
ANALYZE;

-- =====================================================================
-- ÍNDICE 1 — idx_tm_matricula  (B-tree simples, chave estrangeira)
-- Consulta: histórico de um aluno (vw_historico_aluno WHERE id_aluno = ?)
-- O Postgres NÃO indexa FKs automaticamente. A PK de tb_turma_matricula
-- começa por id_turma, então buscar os vínculos DE UMA MATRÍCULA não a
-- usa: sem este índice lê-se a tabela inteira (250 mil linhas).
-- =====================================================================
SELECT '######## ÍNDICE 1 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM vw_historico_aluno WHERE id_aluno = 12345;

CREATE INDEX idx_tm_matricula ON tb_turma_matricula (id_matricula);
ANALYZE tb_turma_matricula;

SELECT '######## ÍNDICE 1 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM vw_historico_aluno WHERE id_aluno = 12345;

-- =====================================================================
-- ÍNDICE 2 — idx_tm_turma_cursando  (B-tree PARCIAL)
-- Consulta: quantos alunos estão cursando uma turma (vagas ocupadas).
--           É a consulta do período de matrícula e da transação do item 3.
-- Parcial porque só os vínculos 'CURSANDO' interessam a essa consulta e
-- são uma fração do total: o índice fica menor e mais barato de manter.
-- A turma 497 é do período atual (2026.2), onde estão os 'CURSANDO'.
-- Obs.: o "antes" já usa a PK (id_turma, ...) e filtra situacao na tabela;
-- o ganho aqui é ler só o índice, e o principal é o TAMANHO (comparado abaixo).
-- =====================================================================
SELECT '######## ÍNDICE 2 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 497 AND situacao = 'CURSANDO';

CREATE INDEX idx_tm_turma_cursando ON tb_turma_matricula (id_turma) WHERE situacao = 'CURSANDO';
ANALYZE tb_turma_matricula;

SELECT '######## ÍNDICE 2 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 497 AND situacao = 'CURSANDO';

SELECT '######## ÍNDICE 2 — parcial x completo (tamanho) ########' AS etapa;
CREATE INDEX idx_tm_turma_full ON tb_turma_matricula (id_turma);
SELECT indexrelid::regclass AS indice,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamanho
FROM pg_index
WHERE indexrelid IN ('idx_tm_turma_cursando'::regclass, 'idx_tm_turma_full'::regclass)
ORDER BY 1;
DROP INDEX idx_tm_turma_full;

-- O parcial só é usado quando o predicado da consulta implica o do índice:
SELECT '######## ÍNDICE 2 — o parcial NÃO é usado se a consulta não filtra a situação ########' AS etapa;
EXPLAIN SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 497;

-- =====================================================================
-- ÍNDICE 3 — idx_matricula_curso_status  (B-tree COMPOSTO)
-- Consulta: matrículas de um curso com determinado status (listas da
--           coordenação). Antes isso ficava em tb_aluno(id_curso,
--           status_aluno); agora curso e status estão em tb_matricula.
--           Igualdade nas duas colunas; id_curso primeiro (mais seletiva
--           e também serve sozinha para "todas as matrículas do curso").
-- =====================================================================
SELECT '######## ÍNDICE 3 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT id_aluno, numero_matricula FROM tb_matricula WHERE id_curso = 5 AND status_matricula = 'TRANCADA';

CREATE INDEX idx_matricula_curso_status ON tb_matricula (id_curso, status_matricula);
ANALYZE tb_matricula;

SELECT '######## ÍNDICE 3 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT id_aluno, numero_matricula FROM tb_matricula WHERE id_curso = 5 AND status_matricula = 'TRANCADA';

-- =====================================================================
-- ÍNDICE 4 — idx_turma_professor  (B-tree, chave estrangeira)
-- Consulta: turmas de um professor (vw_carga_professor / grade).
-- Tabela pequena (1.800 linhas): ganho absoluto modesto, mas é a FK que
-- toda a navegação professor -> turma usa (e o RLS do professor também);
-- custo de manter é desprezível.
-- =====================================================================
SELECT '######## ÍNDICE 4 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT t.id_turma, d.nome_disciplina FROM tb_turma t JOIN tb_disciplina d USING (id_disciplina) WHERE t.id_professor = 77;

CREATE INDEX idx_turma_professor ON tb_turma (id_professor);
ANALYZE tb_turma;

SELECT '######## ÍNDICE 4 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT t.id_turma, d.nome_disciplina FROM tb_turma t JOIN tb_disciplina d USING (id_disciplina) WHERE t.id_professor = 77;

-- =====================================================================
-- ÍNDICE 5 — idx_aluno_nome_lower  (por EXPRESSÃO + text_pattern_ops)
-- Consulta: busca por prefixo do nome, sem diferenciar maiúsculas.
-- Sem o índice, lower(nome) LIKE 'x%' não pode usar índice nenhum;
-- text_pattern_ops permite o LIKE de prefixo em qualquer collation.
-- =====================================================================
SELECT '######## ÍNDICE 5 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT id_aluno, nome_aluno FROM tb_aluno WHERE lower(nome_aluno) LIKE 'diego pereira 123%';

CREATE INDEX idx_aluno_nome_lower ON tb_aluno (lower(nome_aluno) text_pattern_ops);
ANALYZE tb_aluno;

SELECT '######## ÍNDICE 5 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT id_aluno, nome_aluno FROM tb_aluno WHERE lower(nome_aluno) LIKE 'diego pereira 123%';

-- Resumo: tamanho de cada índice criado
SELECT '######## RESUMO — tamanho dos índices ########' AS etapa;
SELECT indexrelid::regclass AS indice, indrelid::regclass AS tabela,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamanho
FROM pg_index
WHERE indexrelid::regclass::text IN ('idx_tm_matricula','idx_tm_turma_cursando',
      'idx_matricula_curso_status','idx_turma_professor','idx_aluno_nome_lower')
ORDER BY 1;
