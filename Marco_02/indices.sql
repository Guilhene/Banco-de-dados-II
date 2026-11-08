-- Marco 2 — 02_indices_dbeaver.sql
-- Versão SEM comandos do psql (\echo, \set, \o...), para rodar no DBeaver/pgAdmin.
-- DBeaver: abra no editor SQL e use 'Executar script' (Alt+X), NÃO Ctrl+Enter.
-- Cada EXPLAIN aparece em uma aba de resultado; as linhas 'etapa' marcam ANTES/DEPOIS.

-- =====================================================================
-- Marco 2 — 02_indices.sql
-- 5 índices (1 parcial, 1 composto, 1 por expressão), cada um com:
--   consulta-alvo -> EXPLAIN (ANALYZE, BUFFERS) ANTES -> CREATE INDEX
--   -> ANALYZE -> EXPLAIN (ANALYZE, BUFFERS) DEPOIS.
-- O script é reexecutável: começa apagando os índices (estado "antes").
-- Cada EXPLAIN roda 1x "de aquecimento" com a saída descartada, para que
-- antes e depois sejam comparados com o cache em condição parecida.
-- Para reproduzir:  psql -h localhost -p 5433 -U bd2 -d matricula -f 02_indices.sql
-- =====================================================================
SET max_parallel_workers_per_gather = 0;   -- plano sem paralelismo: comparação mais limpa

DROP INDEX IF EXISTS idx_matricula_aluno;
DROP INDEX IF EXISTS idx_matricula_turma_ativa;
DROP INDEX IF EXISTS idx_matricula_turma_full;
DROP INDEX IF EXISTS idx_aluno_curso_status;
DROP INDEX IF EXISTS idx_turma_professor;
DROP INDEX IF EXISTS idx_aluno_nome_lower;
ANALYZE;

-- =====================================================================
-- ÍNDICE 1 — idx_matricula_aluno  (B-tree simples, chave estrangeira)
-- Consulta: histórico de um aluno (vw_historico_aluno WHERE id_aluno = ?)
-- O Postgres NÃO indexa FKs automaticamente; sem isso, buscar as
-- matrículas de um aluno lê a tabela inteira.
-- =====================================================================
SELECT '######## ÍNDICE 1 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM vw_historico_aluno WHERE id_aluno = 12345;

CREATE INDEX idx_matricula_aluno ON tb_matricula (id_aluno);
ANALYZE tb_matricula;

SELECT '######## ÍNDICE 1 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM vw_historico_aluno WHERE id_aluno = 12345;

-- =====================================================================
-- ÍNDICE 2 — idx_matricula_turma_ativa  (B-tree PARCIAL)
-- Consulta: quantos alunos ativos há numa turma (vagas ocupadas).
--           É a consulta do período de matrícula e da transação do item 3.
-- Parcial porque só as matrículas 'ativa' interessam a essa consulta e
-- elas são uma fração do total: o índice fica menor e mais barato de
-- manter. Compara-se abaixo com o índice completo equivalente.
-- =====================================================================
SELECT '######## ÍNDICE 2 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM tb_matricula WHERE id_turma = 500 AND status_matricula = 'ativa';

CREATE INDEX idx_matricula_turma_ativa ON tb_matricula (id_turma) WHERE status_matricula = 'ativa';
ANALYZE tb_matricula;

SELECT '######## ÍNDICE 2 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM tb_matricula WHERE id_turma = 500 AND status_matricula = 'ativa';

SELECT '######## ÍNDICE 2 — parcial x completo (tamanho) ########' AS etapa;
CREATE INDEX idx_matricula_turma_full ON tb_matricula (id_turma);
SELECT indexrelid::regclass AS indice,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamanho
FROM pg_index
WHERE indexrelid IN ('idx_matricula_turma_ativa'::regclass, 'idx_matricula_turma_full'::regclass)
ORDER BY 1;
DROP INDEX idx_matricula_turma_full;

-- O parcial só é usado quando o predicado da consulta implica o do índice:
SELECT '######## ÍNDICE 2 — o parcial NÃO é usado se a consulta não filtra status ########' AS etapa;
EXPLAIN SELECT count(*) FROM tb_matricula WHERE id_turma = 500;

-- =====================================================================
-- ÍNDICE 3 — idx_aluno_curso_status  (B-tree COMPOSTO)
-- Consulta: alunos de um curso com determinado status (listas da
--           coordenação). Coluna de igualdade mais seletiva primeiro.
-- =====================================================================
SELECT '######## ÍNDICE 3 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT id_aluno, nome_aluno FROM tb_aluno WHERE id_curso = 5 AND status_aluno = 'trancado';

CREATE INDEX idx_aluno_curso_status ON tb_aluno (id_curso, status_aluno);
ANALYZE tb_aluno;

SELECT '######## ÍNDICE 3 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT id_aluno, nome_aluno FROM tb_aluno WHERE id_curso = 5 AND status_aluno = 'trancado';

-- =====================================================================
-- ÍNDICE 4 — idx_turma_professor  (B-tree, chave estrangeira)
-- Consulta: turmas de um professor (vw_carga_professor / grade).
-- Tabela pequena (1.800 linhas): ganho absoluto modesto, mas é a FK que
-- toda a navegação professor -> turma usa; custo de manter é desprezível.
-- =====================================================================
SELECT '######## ÍNDICE 4 — ANTES ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT t.codigo_turma, d.nome_disciplina FROM tb_turma t JOIN tb_disciplina d USING (id_disciplina) WHERE t.id_professor = 77;

CREATE INDEX idx_turma_professor ON tb_turma (id_professor);
ANALYZE tb_turma;

SELECT '######## ÍNDICE 4 — DEPOIS ########' AS etapa;
EXPLAIN (ANALYZE, BUFFERS) SELECT t.codigo_turma, d.nome_disciplina FROM tb_turma t JOIN tb_disciplina d USING (id_disciplina) WHERE t.id_professor = 77;

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
WHERE indexrelid::regclass::text IN ('idx_matricula_aluno','idx_matricula_turma_ativa',
      'idx_aluno_curso_status','idx_turma_professor','idx_aluno_nome_lower')
ORDER BY 1;
