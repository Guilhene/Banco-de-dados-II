-- =====================================================================
-- Marco 2 — 03_transacoes.sql
-- Roteiro MANUAL (para a apresentação): abra DUAS abas/sessões no pgAdmin ou
-- DBeaver (A e B) e execute os blocos na ordem indicada.
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
-- Autossuficiente: cria os registros mínimos de que a turma e as matrículas
-- dependem (não exige o 00_seed.sql). Ids altos (9001, 90001...) para não
-- colidir com o seed. Pode ser repetida à vontade (reinicia a turma de 1 vaga).
INSERT INTO tb_endereco (id_endereco, estado_endereco, cidade_endereco) VALUES (9001, 'DF', 'Brasília') ON CONFLICT DO NOTHING;
INSERT INTO tb_campus   (id_campus, nome_campus, id_endereco)           VALUES (9001, 'Campus Demo', 9001) ON CONFLICT DO NOTHING;
INSERT INTO tb_curso    (id_curso, nome_curso, grau_curso, chtotal_curso, id_campus) VALUES (9001, 'Curso Demo', 'Bacharelado', 2400, 9001) ON CONFLICT DO NOTHING;
INSERT INTO tb_professor (id_professor, nome_professor, cpf_professor, email_professor, id_campus)
                         VALUES (9001, 'Professor Demo', '99999999001', 'demo.prof@iesb.br', 9001) ON CONFLICT DO NOTHING;
INSERT INTO tb_disciplina (id_disciplina, codigo_disciplina, nome_disciplina, chpratica_disciplina, chteorica_disciplina)
                          VALUES (9001, 'DEMO001', 'Disciplina Demo', 20, 40) ON CONFLICT DO NOTHING;
INSERT INTO tb_aluno (id_aluno, nome_aluno, cpf_aluno, email_aluno, status_aluno, id_curso) VALUES
  (90001, 'Aluno Demo A', '99999990001', 'demo.a@iesb.edu.br', 'ativo', 9001),
  (90002, 'Aluno Demo B', '99999990002', 'demo.b@iesb.edu.br', 'ativo', 9001) ON CONFLICT DO NOTHING;

DELETE FROM tb_matricula WHERE id_turma = 9001;
DELETE FROM tb_turma     WHERE id_turma = 9001;
INSERT INTO tb_turma (id_turma, codigo_turma, turno_turma, vagas_turma, id_disciplina, id_professor)
VALUES (9001, 'DEMO', 'Noite', 1, 9001, 9001);      -- 1 única vaga

-- =====================================================================
-- PARTE 1 — A ANOMALIA (READ COMMITTED, sem proteção)
-- =====================================================================
-- [A] 1.
BEGIN;
-- [A] 2.
SELECT count(*) FROM tb_matricula WHERE id_turma = 9001 AND status_matricula = 'ativa';  -- 0 < 1: tem vaga
-- [B] 3.
BEGIN;
-- [B] 4.
SELECT count(*) FROM tb_matricula WHERE id_turma = 9001 AND status_matricula = 'ativa';  -- 0 < 1: tem vaga (A ainda não gravou)
-- [A] 5.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 90001, 9001);
COMMIT;
-- [B] 6.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 90002, 9001);
COMMIT;
-- [qualquer] 7. Resultado: 2 matriculados numa turma de 1 vaga.
SELECT count(*) AS matriculados FROM tb_matricula WHERE id_turma = 9001 AND status_matricula = 'ativa';  -- 2  (!)

-- =====================================================================
-- CORREÇÃO 1 — TRAVA PESSIMISTA: SELECT ... FOR UPDATE na linha da turma
-- (refazer a PREPARAÇÃO antes). A linha de tb_turma funciona como cadeado
-- da vaga: quem chega depois ESPERA, e ao ser liberado já enxerga a
-- matrícula da outra transação.
-- =====================================================================
-- [A] 1.
BEGIN;
SELECT vagas_turma FROM tb_turma WHERE id_turma = 9001 FOR UPDATE;         -- A pega o cadeado
SELECT count(*) FROM tb_matricula WHERE id_turma = 9001 AND status_matricula = 'ativa';   -- 0
-- [B] 2.
BEGIN;
SELECT vagas_turma FROM tb_turma WHERE id_turma = 9001 FOR UPDATE;         -- B FICA BLOQUEADA aqui
-- [A] 3.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 90001, 9001);
COMMIT;                                                                     -- libera o cadeado
-- [B] 4. (B destravou)
SELECT count(*) FROM tb_matricula WHERE id_turma = 9001 AND status_matricula = 'ativa';   -- 1: SEM vaga
ROLLBACK;                                                                   -- B não insere

-- =====================================================================
-- CORREÇÃO 2 — OTIMISTA: ISOLATION LEVEL SERIALIZABLE + repetição
-- (refazer a PREPARAÇÃO antes). Mesmo código da Parte 1, só muda o
-- isolamento. O banco detecta a dependência cíclica e ABORTA uma das duas
-- com SQLSTATE 40001; a aplicação deve repetir a transação inteira.
-- =====================================================================
-- [A] 1.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_matricula WHERE id_turma = 9001 AND status_matricula = 'ativa';   -- 0
-- [B] 2.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_matricula WHERE id_turma = 9001 AND status_matricula = 'ativa';   -- 0
-- [A] 3.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 90001, 9001);
-- [B] 4.
INSERT INTO tb_matricula (status_matricula, id_aluno, id_turma) VALUES ('ativa', 90002, 9001);
-- [A] 5.
COMMIT;
-- [B] 6. -> ERROR: could not serialize access due to read/write dependencies (40001)
--          (em alguns casos o erro já aparece no INSERT ou no COMMIT de uma das sessões)
COMMIT;      -- vira ROLLBACK
-- [B] 7. REPETIR a transação inteira: agora vê 1 ativa -> sem vaga, não insere.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM tb_matricula WHERE id_turma = 9001 AND status_matricula = 'ativa';   -- 1
ROLLBACK;

-- ---------- LIMPEZA (opcional) ---------------------------------------
-- DELETE FROM tb_matricula WHERE id_turma = 9001; DELETE FROM tb_turma WHERE id_turma = 9001;
-- DELETE FROM tb_aluno WHERE id_aluno IN (90001,90002); DELETE FROM tb_disciplina WHERE id_disciplina = 9001;
-- DELETE FROM tb_professor WHERE id_professor = 9001; DELETE FROM tb_curso WHERE id_curso = 9001;
-- DELETE FROM tb_campus WHERE id_campus = 9001; DELETE FROM tb_endereco WHERE id_endereco = 9001;