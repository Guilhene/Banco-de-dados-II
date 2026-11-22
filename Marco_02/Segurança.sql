-- =====================================================================
-- 02_seguranca_operacao.sql
-- Segurança: roles, permissões e Row-Level Security (RLS)
-- Operação : papel de backup (os comandos estão em backup_restore.sh)
-- Bônus    : log particionado + JSONB/GIN (criados no script 01)


BEGIN;

-- ---------------------------------------------------------------------
-- 1. ENDURECIMENTO: ninguém ganha acesso "de graça"
-- ---------------------------------------------------------------------
DO $$ BEGIN
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
END $$;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 2. PAPÉIS (roles) E USUÁRIOS
--    >>> TROQUE AS SENHAS DE EXEMPLO ANTES DE USAR EM PRODUÇÃO <<<

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['role_aluno','role_professor','role_secretaria','role_auditor'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;

  -- usuário de backup: precisa ler TUDO (BYPASSRLS), mas não escreve nada
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_backup') THEN
    EXECUTE format('CREATE ROLE role_backup LOGIN BYPASSRLS PASSWORD %L', 'TROCAR_senha_backup_1');
  END IF;
END $$;

GRANT pg_read_all_data TO role_backup;   -- PG14+: leitura em todas as tabelas

-- usuários de demonstração (um por papel; dois alunos para testar o RLS)
DO $$
DECLARE u record;
BEGIN
  FOR u IN SELECT * FROM (VALUES
      ('u_aluno1',      'role_aluno'),
      ('u_aluno2',      'role_aluno'),
      ('u_prof1',       'role_professor'),
      ('u_secretaria1', 'role_secretaria'),
      ('u_auditor1',    'role_auditor')
    ) AS t(usuario, papel)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = u.usuario) THEN
      EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L CONNECTION LIMIT 5',
                     u.usuario, 'TROCAR_senha_' || u.usuario);
    END IF;
    EXECUTE format('GRANT %I TO %I', u.papel, u.usuario);
  END LOOP;
END $$;

DO $$ BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO role_aluno, role_professor, role_secretaria, role_auditor, role_backup',
                 current_database());
END $$;
GRANT USAGE ON SCHEMA public TO role_aluno, role_professor, role_secretaria, role_auditor, role_backup;

-- ---------------------------------------------------------------------
-- 3. PERMISSÕES POR TABELA (GRANT) - menor privilégio
--    O GRANT diz QUAIS tabelas/colunas; o RLS (seção 5) diz QUAIS LINHAS.

-- 3.1 Tabelas de consulta geral (dados não sensíveis)
GRANT SELECT ON tb_curso, tb_disciplina, tb_curso_disciplina, tb_requisito,
                tb_turma, tb_periodo_letivo, tb_horario, tb_sala, tb_campus,
                tb_calendario, tb_eventos_calendario
  TO role_aluno, role_professor;

-- 3.2 ALUNO: só leitura, e o RLS limita às próprias linhas
GRANT SELECT ON tb_aluno, tb_endereco_aluno, tb_matricula,
                tb_turma_matricula, tb_log_matricula
  TO role_aluno;

-- 3.3 PROFESSOR: sem CPF/endereço; altera só nota, frequência e situação
GRANT SELECT (id_professor, nome_professor, email_professor, usuario_bd)
  ON tb_professor TO role_professor;
GRANT SELECT (id_aluno, nome_aluno, email_aluno)
  ON tb_aluno TO role_professor;
GRANT SELECT (id_matricula, id_aluno, id_curso, numero_matricula, status_matricula)
  ON tb_matricula TO role_professor;
GRANT SELECT ON tb_turma_matricula TO role_professor;
GRANT UPDATE (nota, frequencia, situacao) ON tb_turma_matricula TO role_professor;

-- 3.4 SECRETARIA: cadastra e atualiza, mas nunca apaga (sem DELETE)
GRANT SELECT, INSERT, UPDATE ON
  tb_aluno, tb_endereco_aluno, tb_professor, tb_matricula,
  tb_curso, tb_disciplina, tb_curso_disciplina, tb_requisito, tb_turma,
  tb_periodo_letivo, tb_horario, tb_sala, tb_campus, tb_endereco_campus,
  tb_calendario, tb_eventos_calendario
  TO role_secretaria;
GRANT SELECT, INSERT ON tb_turma_matricula TO role_secretaria;
GRANT UPDATE (situacao) ON tb_turma_matricula TO role_secretaria;

-- 3.5 AUDITOR: só lê o log
GRANT SELECT ON tb_log_matricula TO role_auditor;

-- ---------------------------------------------------------------------
-- 4. FUNÇÕES AUXILIARES (executam com os direitos de quem chama,
--    então a própria RLS de tb_aluno/tb_professor já se aplica)

CREATE OR REPLACE FUNCTION fn_id_aluno_atual() RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT id_aluno FROM tb_aluno WHERE usuario_bd = current_user
$$;

CREATE OR REPLACE FUNCTION fn_id_professor_atual() RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT id_professor FROM tb_professor WHERE usuario_bd = current_user
$$;

GRANT EXECUTE ON FUNCTION fn_id_aluno_atual(), fn_id_professor_atual()
  TO role_aluno, role_professor, role_secretaria;

-- ---------------------------------------------------------------------
-- 5. ROW-LEVEL SECURITY
--    Com RLS ligado e sem policy aplicável, o papel não vê NENHUMA linha.
--    USING      = linhas que a pessoa enxerga / pode atualizar
--    WITH CHECK = como a linha pode ficar depois de gravada

ALTER TABLE tb_aluno           ENABLE ROW LEVEL SECURITY;
ALTER TABLE tb_endereco_aluno  ENABLE ROW LEVEL SECURITY;
ALTER TABLE tb_professor       ENABLE ROW LEVEL SECURITY;
ALTER TABLE tb_matricula       ENABLE ROW LEVEL SECURITY;
ALTER TABLE tb_turma_matricula ENABLE ROW LEVEL SECURITY;
ALTER TABLE tb_log_matricula   ENABLE ROW LEVEL SECURITY;

-- 5.1 tb_aluno ------------------------------------------------------
CREATE POLICY aluno_ve_a_si_mesmo ON tb_aluno
  FOR SELECT TO role_aluno
  USING (usuario_bd = current_user);

CREATE POLICY professor_ve_alunos_das_suas_turmas ON tb_aluno
  FOR SELECT TO role_professor
  USING (id_aluno IN (SELECT id_aluno FROM tb_matricula));   -- tb_matricula já é filtrada

CREATE POLICY secretaria_total ON tb_aluno
  FOR ALL TO role_secretaria USING (true) WITH CHECK (true);

-- 5.2 tb_endereco_aluno ---------------------------------------------
CREATE POLICY aluno_ve_o_proprio_endereco ON tb_endereco_aluno
  FOR SELECT TO role_aluno
  USING (id_endereco_aluno = (SELECT id_endereco_aluno FROM tb_aluno WHERE usuario_bd = current_user));

CREATE POLICY secretaria_total ON tb_endereco_aluno
  FOR ALL TO role_secretaria USING (true) WITH CHECK (true);

-- 5.3 tb_professor ---------------------------------------------------
CREATE POLICY professor_ve_a_si_mesmo ON tb_professor
  FOR SELECT TO role_professor
  USING (usuario_bd = current_user);

CREATE POLICY secretaria_total ON tb_professor
  FOR ALL TO role_secretaria USING (true) WITH CHECK (true);

-- 5.4 tb_matricula ---------------------------------------------------
CREATE POLICY aluno_ve_as_proprias_matriculas ON tb_matricula
  FOR SELECT TO role_aluno
  USING (id_aluno = fn_id_aluno_atual());

CREATE POLICY professor_ve_matriculas_das_suas_turmas ON tb_matricula
  FOR SELECT TO role_professor
  USING (id_matricula IN (SELECT id_matricula FROM tb_turma_matricula));  -- já filtrada

CREATE POLICY secretaria_total ON tb_matricula
  FOR ALL TO role_secretaria USING (true) WITH CHECK (true);

-- 5.5 tb_turma_matricula (histórico escolar: notas, frequência) ------
CREATE POLICY aluno_ve_o_proprio_historico ON tb_turma_matricula
  FOR SELECT TO role_aluno
  USING (id_matricula IN (SELECT id_matricula FROM tb_matricula
                           WHERE id_aluno = fn_id_aluno_atual()));

CREATE POLICY professor_le_suas_turmas ON tb_turma_matricula
  FOR SELECT TO role_professor
  USING (id_turma IN (SELECT id_turma FROM tb_turma
                       WHERE id_professor = fn_id_professor_atual()));

CREATE POLICY professor_lanca_notas_nas_suas_turmas ON tb_turma_matricula
  FOR UPDATE TO role_professor
  USING      (id_turma IN (SELECT id_turma FROM tb_turma WHERE id_professor = fn_id_professor_atual()))
  WITH CHECK (id_turma IN (SELECT id_turma FROM tb_turma WHERE id_professor = fn_id_professor_atual()));

CREATE POLICY secretaria_le_e_matricula ON tb_turma_matricula
  FOR SELECT TO role_secretaria USING (true);
CREATE POLICY secretaria_insere ON tb_turma_matricula
  FOR INSERT TO role_secretaria WITH CHECK (true);
CREATE POLICY secretaria_atualiza_situacao ON tb_turma_matricula
  FOR UPDATE TO role_secretaria USING (true) WITH CHECK (true);

-- 5.6 tb_log_matricula (histórico/auditoria) -------------------------
-- Aluno só enxerga o log das próprias matrículas; auditor enxerga tudo.
-- Os INSERTs vêm do trigger (SECURITY DEFINER), então não há policy de escrita.
CREATE POLICY aluno_ve_o_proprio_log ON tb_log_matricula
  FOR SELECT TO role_aluno
  USING (id_matricula IN (SELECT id_matricula FROM tb_matricula
                           WHERE id_aluno = fn_id_aluno_atual()));

CREATE POLICY auditor_ve_tudo ON tb_log_matricula
  FOR SELECT TO role_auditor USING (true);

-- ---------------------------------------------------------------------
-- 6. VIEW DO HISTÓRICO ESCOLAR
--    security_invoker = true: a view respeita o RLS de quem consulta.
--    (Sem isso, a view rodaria com os direitos do dono e IGNORARIA o RLS.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_historico_escolar
WITH (security_invoker = true) AS
SELECT m.numero_matricula,
       c.nome_curso,
       p.ano_periodo_letivo      AS ano,
       p.semestre_periodo_letivo AS semestre,
       d.codigo_disciplina,
       d.nome_disciplina,
       tm.nota,
       tm.frequencia,
       tm.situacao
FROM tb_matricula m
JOIN tb_curso            c  ON c.id_curso            = m.id_curso
JOIN tb_turma_matricula  tm ON tm.id_matricula       = m.id_matricula
JOIN tb_turma            t  ON t.id_turma            = tm.id_turma
JOIN tb_disciplina       d  ON d.id_disciplina       = t.id_disciplina
JOIN tb_periodo_letivo   p  ON p.id_periodo_letivo   = t.id_periodo_letivo;

GRANT SELECT ON vw_historico_escolar TO role_aluno, role_professor, role_secretaria;

COMMIT;


-- =====================================================================
-- 7. TESTES (rodam tudo dentro de uma transação e terminam em ROLLBACK:
--    não deixam dados de demonstração no banco)

BEGIN;

-- dados de demonstração
INSERT INTO tb_endereco_campus VALUES (1,'DF','Brasília','70000000','Asa Norte');
INSERT INTO tb_campus VALUES (1,1,'Campus Central','12345678000199');
INSERT INTO tb_curso (id_curso, id_campus, nome_curso, grau_curso, codigo_curso)
  VALUES (1,1,'Ciência da Computação','Bacharelado','101');
INSERT INTO tb_endereco_aluno VALUES (1,'DF','Brasília','70000001','Rua A, 10'),
                                     (2,'DF','Brasília','70000002','Rua B, 20');
INSERT INTO tb_aluno (id_aluno,id_endereco_aluno,nome_aluno,cpf_aluno,email_aluno,nascimento_aluno,usuario_bd)
  VALUES (1,1,'Maria','11111111111','maria@uni.edu','2005-01-10','u_aluno1'),
         (2,2,'João', '22222222222','joao@uni.edu', '2004-05-20','u_aluno2');
INSERT INTO tb_professor (id_professor,nome_professor,cpf_professor,email_professor,registro_funcional,usuario_bd)
  VALUES (1,'Profa. Ana','33333333333','ana@uni.edu','RF001','u_prof1');
INSERT INTO tb_disciplina (id_disciplina,codigo_disciplina,nome_disciplina) VALUES (1,'BD01','Banco de Dados');
INSERT INTO tb_periodo_letivo VALUES (1,1,2026,'2026-02-01','2026-07-01');
INSERT INTO tb_horario VALUES (1,'SEG','08:00','10:00');
INSERT INTO tb_sala VALUES (1,1,'Laboratório',40,'A101','1');
INSERT INTO tb_turma VALUES (1,1,1,1,1,1);

-- matrícula automática (um INSERT por vez): esperado 261010001 e 261010002
INSERT INTO tb_matricula (id_matricula,id_aluno,id_curso,data_inicio_matricula) VALUES (1,1,1,'2026-02-01');
INSERT INTO tb_matricula (id_matricula,id_aluno,id_curso,data_inicio_matricula) VALUES (2,2,1,'2026-02-01');
SELECT id_matricula, numero_matricula FROM tb_matricula ORDER BY 1;

INSERT INTO tb_turma_matricula (id_turma,id_matricula,nota,frequencia) VALUES (1,1,8.5,90), (1,2,6.0,80);

-- 7.1 Maria (aluno 1) deve ver SÓ o próprio histórico
SET LOCAL ROLE u_aluno1;
SELECT 'u_aluno1' AS quem, numero_matricula, nome_disciplina, nota FROM vw_historico_escolar;
SELECT 'u_aluno1' AS quem, count(*) AS linhas_visiveis_tb_aluno FROM tb_aluno;              -- 1
RESET ROLE;

-- 7.2 João (aluno 2) tenta ler o histórico da matrícula 1 (da Maria): 0 linhas
SET LOCAL ROLE u_aluno2;
SELECT 'u_aluno2' AS quem, count(*) AS linhas_da_maria FROM tb_turma_matricula WHERE id_matricula = 1;  -- 0
SELECT 'u_aluno2' AS quem, numero_matricula, nota FROM vw_historico_escolar;                            -- só o dele
RESET ROLE;

-- 7.3 Professora lança nota na sua turma (permitido)
SET LOCAL ROLE u_prof1;
UPDATE tb_turma_matricula SET nota = 9.0 WHERE id_matricula = 1;                                        -- UPDATE 1
RESET ROLE;

-- 7.4 Bloqueios esperados (cada um dentro de um bloco que captura o erro)
DO $$
BEGIN
  SET LOCAL ROLE u_aluno1;
  UPDATE tb_turma_matricula SET nota = 10;
  RAISE EXCEPTION 'FALHA: aluno conseguiu alterar nota';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: aluno NÃO pode alterar notas';
END $$;

DO $$
BEGIN
  SET LOCAL ROLE u_prof1;
  PERFORM cpf_aluno FROM tb_aluno;
  RAISE EXCEPTION 'FALHA: professor leu CPF de aluno';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: professor NÃO enxerga CPF';
END $$;

DO $$
BEGIN
  SET LOCAL ROLE u_secretaria1;
  DELETE FROM tb_matricula;
  RAISE EXCEPTION 'FALHA: secretaria conseguiu apagar matrículas';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: secretaria NÃO apaga matrículas';
END $$;

DO $$
BEGIN
  UPDATE tb_log_matricula SET acao_log_matricula = 'X';
  RAISE EXCEPTION 'FALHA: log foi alterado';
EXCEPTION WHEN raise_exception THEN
  RAISE NOTICE 'OK: log é imutável';
END $$;

-- 7.5 Auditor lê o log; consulta no JSONB usa o índice GIN
SET LOCAL ROLE u_auditor1;
SELECT id_matricula, acao_log_matricula, usuario_log_matricula,
       detalhe->>'tabela' AS tabela
FROM tb_log_matricula
WHERE detalhe @> '{"tabela":"tb_turma_matricula"}'
ORDER BY id_log_matricula;
RESET ROLE;

-- 7.6 Particionamento: cada registro caiu na partição do seu ano
SELECT tableoid::regclass AS particao, count(*) FROM tb_log_matricula GROUP BY 1;

-- poda de partições: o plano deve citar só tb_log_matricula_2026
EXPLAIN (COSTS OFF)
SELECT * FROM tb_log_matricula
WHERE data_ocorrido >= '2026-01-01' AND data_ocorrido < '2027-01-01';

-- uso do índice GIN (seqscan desligado só para a demonstração)
SET LOCAL enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT * FROM tb_log_matricula WHERE detalhe @> '{"tabela":"tb_matricula"}';

ROLLBACK;

