-- *** NÃO EXECUTE ESTE ARQUIVO INTEIRO (Alt+X). ***
-- =====================================================================
-- Marco 2 — 03_transacoes.sql   (adaptado ao esquema atual do banco)
--
-- ORDEM DE EXECUÇÃO (sempre na mesma base):
--   1) instalar_tudo.sql  -> tabelas, segurança e dados
--   2) 01_views.sql       -> views + materialized view
--   3) 02_indices.sql     -> índices + EXPLAIN
--   4) 03_transacoes.sql  -> ESTE arquivo: anomalia e correções
-- É um roteiro MANUAL para DUAS sessões concorrentes (A e B), para a apresentação:
--   * abra DUAS abas de editor, cada uma com sua PRÓPRIA conexão (pgAdmin/DBeaver);
--   * execute UM comando por vez (Ctrl+Enter), na ordem dos comentários [A]/[B];
--   * só a PREPARAÇÃO pode ser executada de uma vez.
-- Se rodar o arquivo todo numa única conexão, o banco avisa "there is already a
-- transaction in progress" / "there is no transaction in progress": são avisos
-- (não erros) porque os BEGIN/COMMIT de A e B se misturam, e a anomalia NÃO aparece.
--
-- ANOMALIA: "matrícula acima das vagas" (overbooking).
--   Regra de negócio: alunos CURSANDO <= vagas da turma.
--   No esquema atual, vagas da turma = capacidade da sala (tb_sala.capacidade_sala)
--   e a matrícula na turma é uma linha de tb_turma_matricula (situacao='CURSANDO').
--   A regra é garantida só pela APLICAÇÃO (ler a contagem e depois inserir).
--   Duas transações leem a contagem ao mesmo tempo, ambas veem "há vaga" e
--   ambas inserem. Cada uma, isolada, está correta; juntas violam a regra.
--   É um write skew / fantasma (check-then-act): um CHECK ou FK não vê isso,
--   porque a regra envolve a contagem de OUTRAS linhas.
--   Ocorre em READ COMMITTED (padrão) e também em REPEATABLE READ (o
--   Postgres implementa snapshot isolation, que permite write skew).
--
-- Obs.: a tabela tb_turma_matricula tem trigger de auditoria; cada INSERT
-- abaixo também grava uma linha em tb_log_matricula (isso é esperado).
-- =====================================================================

-- ---------- PREPARAÇÃO (uma vez, em qualquer sessão) ----------------
--   * turma 1 (período 2024.2, sem ninguém CURSANDO na carga);
--   * criamos uma sala exclusiva de DEMONSTRAÇÃO com capacidade 1 (id 9001) e
--     ligamos a turma 1 a ela. Assim as vagas da turma passam a ser 1 SEM
--     alterar a capacidade das salas reais, que são compartilhadas por várias turmas;
--   * matrículas 100 e 101: ATIVAS e sem vínculo anterior com a turma 1, ou seja,
--     aptas a se matricular.
-- Pode ser repetida à vontade: devolve a turma ao estado "1 vaga, 0 cursando".
INSERT INTO tb_sala (id_sala, id_campus, tipo_sala, capacidade_sala, codigo_sala, andar_sala)
VALUES (9001, 1, 'Demo transações', 1, 'DEMO-9001', '0')
ON CONFLICT (id_sala) DO UPDATE SET capacidade_sala = 1;
UPDATE tb_turma SET id_sala = 9001 WHERE id_turma = 1;
DELETE FROM tb_turma_matricula WHERE id_turma = 1 AND id_matricula IN (100, 101);

-- Conferência (deve mostrar a turma 1 com 1 vaga e 0 cursando, e as 2 matrículas 'ATIVA'):
SELECT t.id_turma, s.capacidade_sala AS vagas,
       (SELECT count(*) FROM tb_turma_matricula x
         WHERE x.id_turma = t.id_turma AND x.situacao = 'CURSANDO') AS cursando
FROM   tb_turma t JOIN tb_sala s ON s.id_sala = t.id_sala WHERE t.id_turma = 1;
SELECT id_matricula, id_aluno, status_matricula FROM tb_matricula WHERE id_matricula IN (100, 101) ORDER BY 1;

-- =====================================================================
-- PARTE 1 — A ANOMALIA (READ COMMITTED, sem proteção)
-- =====================================================================
-- [A] 1.
BEGIN;
-- [A] 2.
SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 1 AND situacao = 'CURSANDO';  -- 0 < 1: tem vaga
-- [B] 3.
BEGIN;
-- [B] 4.
SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 1 AND situacao = 'CURSANDO';  -- 0 < 1: tem vaga (A ainda não gravou)
-- [A] 5.
INSERT INTO tb_turma_matricula (id_turma, id_matricula, situacao) VALUES (1, 100, 'CURSANDO');
COMMIT;
-- [B] 6.
INSERT INTO tb_turma_matricula (id_turma, id_matricula, situacao) VALUES (1, 101, 'CURSANDO');
COMMIT;
-- [qualquer] 7. Resultado: 2 cursando numa turma de 1 vaga.
SELECT count(*) AS cursando FROM tb_turma_matricula WHERE id_turma = 1 AND situacao = 'CURSANDO';  -- 2  (!)

-- =====================================================================
-- CORREÇÃO 1 — TRAVA PESSIMISTA: SELECT ... FOR UPDATE na linha da turma
-- (refazer a PREPARAÇÃO antes). A linha de tb_turma funciona como cadeado
-- da vaga: quem chega depois ESPERA, e ao ser liberado já enxerga a
-- matrícula da outra transação. (FOR UPDATE OF t trava só a linha da
-- turma, não a da sala.)
-- =====================================================================
-- [A] 1.
BEGIN;
SELECT s.capacidade_sala AS vagas FROM tb_turma t JOIN tb_sala s ON s.id_sala = t.id_sala
 WHERE t.id_turma = 1 FOR UPDATE OF t;                                      -- A pega o cadeado
SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 1 AND situacao = 'CURSANDO';   -- 0
-- [B] 2.
BEGIN;
SELECT s.capacidade_sala AS vagas FROM tb_turma t JOIN tb_sala s ON s.id_sala = t.id_sala
 WHERE t.id_turma = 1 FOR UPDATE OF t;                                      -- B FICA BLOQUEADA aqui
-- [A] 3.
INSERT INTO tb_turma_matricula (id_turma, id_matricula, situacao) VALUES (1, 100, 'CURSANDO');
COMMIT;                                                                     -- libera o cadeado
-- [B] 4. (B destravou)
SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 1 AND situacao = 'CURSANDO';   -- 1: SEM vaga
ROLLBACK;                                                                   -- B não insere

-- =====================================================================
-- CORREÇÃO 2 — OTIMISTA: ISOLATION LEVEL SERIALIZABLE + repetição
-- (refazer a PREPARAÇÃO antes). Mesmo código da Parte 1, só muda o
-- isolamento. O banco detecta a dependência cíclica e ABORTA uma das duas
-- com SQLSTATE 40001; a aplicação deve repetir a transação inteira.
-- =====================================================================
-- [A] 1.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 1 AND situacao = 'CURSANDO';   -- 0
-- [B] 2.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 1 AND situacao = 'CURSANDO';   -- 0
-- [A] 3.
INSERT INTO tb_turma_matricula (id_turma, id_matricula, situacao) VALUES (1, 100, 'CURSANDO');
-- [B] 4.
INSERT INTO tb_turma_matricula (id_turma, id_matricula, situacao) VALUES (1, 101, 'CURSANDO');
-- [A] 5.
COMMIT;
-- [B] 6. -> ERROR: could not serialize access due to read/write dependencies (40001)
--          (em alguns casos o erro já aparece no INSERT ou no COMMIT de uma das sessões)
COMMIT;      -- vira ROLLBACK
-- [B] 7. REPETIR a transação inteira: agora vê 1 cursando -> sem vaga, não insere.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_turma_matricula WHERE id_turma = 1 AND situacao = 'CURSANDO';   -- 1
ROLLBACK;

-- ---------- LIMPEZA (obrigatória ao terminar a demonstração) ----------
-- Devolve a turma 1 à sala original (id 8) e remove a sala de demonstração:
-- DELETE FROM tb_turma_matricula WHERE id_turma = 1 AND id_matricula IN (100, 101);
-- UPDATE tb_turma SET id_sala = 8 WHERE id_turma = 1;
-- DELETE FROM tb_sala WHERE id_sala = 9001;
