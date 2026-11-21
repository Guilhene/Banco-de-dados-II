-- *** NÃO EXECUTE ESTE ARQUIVO INTEIRO (Alt+X). ***
-- =====================================================================
-- Marco 2 — 03_transacoes.sql
--
-- ORDEM DE EXECUÇÃO (sempre na base "matricula"):
--   1) Marco_01.sql   -> cria as tabelas (sem a linha CREATE DATABASE)
--   2) 00_dados.sql   -> carga de dados geral (~50 mil alunos, ~264 mil matrículas)
--   3) 01_views.sql   -> views + materialized view
--   4) 02_indices.sql -> índices + EXPLAIN
--   5) 03_transacoes.sql -> anomalia e correções (usa turma e alunos da carga do passo 2)
-- É um roteiro MANUAL para DUAS sessões concorrentes (A e B), para a apresentação:
--   * abra DUAS abas de editor, cada uma com sua PRÓPRIA conexão (pgAdmin/DBeaver);
--   * execute UM comando por vez (Ctrl+Enter), na ordem dos comentários [A]/[B];
--   * só a PREPARAÇÃO pode ser executada de uma vez.
-- Se rodar o arquivo todo numa única conexão, o banco avisa "there is already a
-- transaction in progress" / "there is no transaction in progress": são avisos
-- (não erros) porque os BEGIN/COMMIT de A e B se misturam, e a anomalia NÃO aparece.
-- A versão automática (duas sessões sozinhas) está em transacoes/executar_demo.sh
-- e executar_carga.sh.
--
-- ANOMALIA: "matrícula acima das vagas" (overbooking).
--   Regra de negócio: matriculados ativos <= vagas_turma.
--   A regra é garantida só pela APLICAÇÃO (ler a contagem e depois inserir).
--   Duas transações leem a contagem ao mesmo tempo, ambas veem "há vaga" e
--   ambas inserem. Cada uma, isolada, está correta; juntas violam a regra.
--   É um write skew / fantasma (check-then-act): um CHECK ou FK não vê isso,
--   porque a regra envolve a contagem de OUTRAS linhas.
--   Ocorre em READ COMMITTED (padrão) e também em REPEATABLE READ (o
--   Postgres implementa snapshot isolation, que permite write skew).
-- =====================================================================

-- ---------- PREPARAÇÃO (uma vez, em qualquer sessão) ----------------
--   * turma 3009 = '2026.2-RED101-900' (RED101 não tem pré-requisito), criada
--     VAZIA pela carga; aqui só reduzimos as vagas para 1;
--   * alunos 107 (Hugo Pereira 107) e 113 (Diego Souza 113): ativos e sem
--     nenhuma matrícula anterior em RED101, ou seja, aptos a se matricular.
-- Pode ser repetida à vontade: devolve a turma ao estado "1 vaga, 0 matriculados".
UPDATE tb_turma SET vagas_turma = 1 WHERE id_turma = 3009;
DELETE FROM tb_matricula WHERE id_turma = 3009;

-- Conferência (deve mostrar a turma RED101-900 com 1 vaga e 0 ativos, e os 2 alunos 'ativo'):
SELECT t.id_turma, t.codigo_turma, t.vagas_turma,
       (SELECT count(*) FROM tb_matricula m WHERE m.id_turma = t.id_turma AND m.status_matricula = 'ativa') AS ativos
FROM   tb_turma t WHERE t.id_turma = 3009;
SELECT id_aluno, nome_aluno, status_aluno FROM tb_aluno WHERE id_aluno IN (107, 113) ORDER BY id_aluno;

-- =====================================================================
-- PARTE 1 — A ANOMALIA (READ COMMITTED, sem proteção)
-- =====================================================================
-- [A] 1.
BEGIN;
-- [A] 2.
SELECT count(*) FROM tb_matricula WHERE id_turma = 3009 AND status_matricula = 'ativa';  -- 0 < 1: tem vaga
-- [B] 3.
BEGIN;
-- [B] 4.
SELECT count(*) FROM tb_matricula WHERE id_turma = 3009 AND status_matricula = 'ativa';  -- 0 < 1: tem vaga (A ainda não gravou)
-- [A] 5.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 107, 3009);
COMMIT;
-- [B] 6.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 113, 3009);
COMMIT;
-- [qualquer] 7. Resultado: 2 matriculados numa turma de 1 vaga.
SELECT count(*) AS matriculados FROM tb_matricula WHERE id_turma = 3009 AND status_matricula = 'ativa';  -- 2  (!)

-- =====================================================================
-- CORREÇÃO 1 — TRAVA PESSIMISTA: SELECT ... FOR UPDATE na linha da turma
-- (refazer a PREPARAÇÃO antes). A linha de tb_turma funciona como cadeado
-- da vaga: quem chega depois ESPERA, e ao ser liberado já enxerga a
-- matrícula da outra transação.
-- =====================================================================
-- [A] 1.
BEGIN;
SELECT vagas_turma FROM tb_turma WHERE id_turma = 3009 FOR UPDATE;         -- A pega o cadeado
SELECT count(*) FROM tb_matricula WHERE id_turma = 3009 AND status_matricula = 'ativa';   -- 0
-- [B] 2.
BEGIN;
SELECT vagas_turma FROM tb_turma WHERE id_turma = 3009 FOR UPDATE;         -- B FICA BLOQUEADA aqui
-- [A] 3.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 107, 3009);
COMMIT;                                                                     -- libera o cadeado
-- [B] 4. (B destravou)
SELECT count(*) FROM tb_matricula WHERE id_turma = 3009 AND status_matricula = 'ativa';   -- 1: SEM vaga
ROLLBACK;                                                                   -- B não insere

-- =====================================================================
-- CORREÇÃO 2 — OTIMISTA: ISOLATION LEVEL SERIALIZABLE + repetição
-- (refazer a PREPARAÇÃO antes). Mesmo código da Parte 1, só muda o
-- isolamento. O banco detecta a dependência cíclica e ABORTA uma das duas
-- com SQLSTATE 40001; a aplicação deve repetir a transação inteira.
-- =====================================================================
-- [A] 1.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_matricula WHERE id_turma = 3009 AND status_matricula = 'ativa';   -- 0
-- [B] 2.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_matricula WHERE id_turma = 3009 AND status_matricula = 'ativa';   -- 0
-- [A] 3.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 107, 3009);
-- [B] 4.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 113, 3009);
-- [A] 5.
COMMIT;
-- [B] 6. -> ERROR: could not serialize access due to read/write dependencies (40001)
--          (em alguns casos o erro já aparece no INSERT ou no COMMIT de uma das sessões)
COMMIT;      -- vira ROLLBACK
-- [B] 7. REPETIR a transação inteira: agora vê 1 ativa -> sem vaga, não insere.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_matricula WHERE id_turma = 3009 AND status_matricula = 'ativa';   -- 1
ROLLBACK;

-- ---------- LIMPEZA (opcional) ---------------------------------------
-- Devolve a turma 3009 ao estado original da carga (60 vagas, sem matrículas):
-- DELETE FROM tb_matricula WHERE id_turma = 3009;
-- UPDATE tb_turma SET vagas_turma = 60 WHERE id_turma = 3009;
