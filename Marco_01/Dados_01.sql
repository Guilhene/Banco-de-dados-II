-- =====================================================================
-- 00_dados.sql - Dados sintéticos para dar volume ao banco
--
-- Requisitos: PostgreSQL 15+
-- Ordem: banco_de_dado.sql -> 01_alteracoes_banco.sql
--        -> 02_seguranca_operacao.sql -> ESTE script
--
-- Rodar como dono/superusuário, em banco VAZIO (sem os dados de teste do
-- script 02, que também usam ids 1, 2...). Para recarregar, use o bloco
-- de limpeza logo abaixo.
--
-- Volume gerado: 5 campi | 12 cursos | 200 professores | 60 disciplinas
--   1.800 turmas | 50.000 alunos | 50.000 matrículas | 250.000 vínculos
--   turma x matrícula | ~200.000 linhas de log (2024-2026)

-- LIMPEZA (descomente para recarregar em um banco que já tem dados)
-- TRUNCATE tb_log_matricula, tb_turma_matricula, tb_matricula, tb_aluno,
--          tb_endereco_aluno, tb_turma, tb_eventos_calendario, tb_calendario,
--          tb_sala, tb_periodo_letivo, tb_horario, tb_requisito,
--          tb_curso_disciplina, tb_disciplina, tb_professor, tb_curso,
--          tb_campus, tb_endereco_campus;

DO $$
DECLARE
  falta text[] := '{}';
BEGIN
  IF current_setting('server_version_num')::int < 150000 THEN
    falta := falta || ('PostgreSQL 15+ (versão atual: ' || current_setting('server_version') || ')');
  END IF;
  IF to_regclass('public.tb_log_matricula') IS NULL THEN
    falta := falta || 'tabela tb_log_matricula'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'tb_matricula' AND column_name = 'numero_matricula') THEN
    falta := falta || 'coluna tb_matricula.numero_matricula'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'tb_curso' AND column_name = 'codigo_curso') THEN
    falta := falta || 'coluna tb_curso.codigo_curso'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'tb_aluno' AND column_name = 'usuario_bd') THEN
    falta := falta || 'coluna tb_aluno.usuario_bd'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'tb_professor' AND column_name = 'usuario_bd') THEN
    falta := falta || 'coluna tb_professor.usuario_bd'::text;
  END IF;

  IF cardinality(falta) > 0 THEN
    RAISE EXCEPTION E'Pré-requisitos ausentes: %.\nRode ANTES o 01_alteracoes_banco.sql inteiro (no DBeaver: Executar script, Alt+X; não Ctrl+Enter, que roda só um comando).',
      array_to_string(falta, '; ');
  END IF;
END $$;

BEGIN;

SELECT setseed(0.42);

-- Os triggers de numeração e auditoria são pensados para 1 linha por vez.
-- Na carga em massa eles são desligados: o número da matrícula é gerado
-- aqui, em lote, no MESMO formato (AA + curso + sequencial) e o log é
-- preenchido abaixo. Ao final os triggers voltam a ficar ativos.
ALTER TABLE tb_matricula       DISABLE TRIGGER USER;
ALTER TABLE tb_turma_matricula DISABLE TRIGGER USER;

-- ENDEREÇO DO CAMPUS / CAMPUS (5) --------------------------------------
INSERT INTO tb_endereco_campus (id_endereco_campus, estado, cidade, cep, logradouro)
SELECT g,
       (ARRAY['DF','GO','SP','RJ','MG'])[g],
       (ARRAY['Brasília','Goiânia','São Paulo','Rio de Janeiro','Belo Horizonte'])[g],
       lpad((70000000 + g * 1000)::text, 8, '0'),
       'Avenida Principal, ' || (g * 100)
FROM generate_series(1,5) g;

INSERT INTO tb_campus (id_campus, id_endereco_campus, nome_campus, cnpj_endereco)
SELECT id_endereco_campus, id_endereco_campus, 'Campus ' || cidade,
       lpad(id_endereco_campus::text, 14, '0')
FROM tb_endereco_campus;

-- CURSO (12 cursos distribuídos pelos campi) ---------------------------
-- codigo_curso (101..112) compõe o número da matrícula.
INSERT INTO tb_curso (id_curso, id_campus, nome_curso, grau_curso, codigo_curso)
SELECT g,
       1 + g % 5,
       (ARRAY['Ciência da Computação','Engenharia de Software','Sistemas de Informação',
              'Administração','Direito','Psicologia','Engenharia Civil',
              'Arquitetura e Urbanismo','Medicina Veterinária','Design Gráfico',
              'Ciências Contábeis','Pedagogia'])[g],
       (ARRAY['Bacharelado','Licenciatura','Tecnólogo'])[1 + g % 3],
       (100 + g)::text
FROM generate_series(1,12) g;

-- PROFESSOR (200) ------------------------------------------------------
INSERT INTO tb_professor (id_professor, nome_professor, cpf_professor, email_professor,
                          registro_funcional)
SELECT g, 'Professor ' || g, lpad(g::text, 11, '0'), 'prof' || g || '@iesb.br',
       'RF' || lpad(g::text, 6, '0')
FROM generate_series(1,200) g;

-- DISCIPLINA (60) ---------------------------------------------------------
INSERT INTO tb_disciplina (id_disciplina, codigo_disciplina, nome_disciplina,
                           hora_pratica_disciplina, hora_teorica_disciplina)
SELECT g, 'DISC' || lpad(g::text, 3, '0'), 'Disciplina ' || g,
       ((g % 3) * 20) * interval '1 hour',
       (40 + (g % 2) * 20) * interval '1 hour'
FROM generate_series(1,60) g;

-- CURSO x DISCIPLINA (grade: ~25 disciplinas por curso) -----------------
INSERT INTO tb_curso_disciplina (id_curso, id_disciplina, carga_horario_total_curso)
SELECT c, d, (d % 3) * 20 + 40 + (d % 2) * 20
FROM generate_series(1,12) c, generate_series(1,60) d
WHERE (d + c) % 12 < 5;

-- REQUISITO (pré-requisito de algumas disciplinas) ------------------------
INSERT INTO tb_requisito (id_requisito, id_disciplina, requisito_diciplina)
SELECT g, g, 'DISC' || lpad((g - 10)::text, 3, '0')
FROM generate_series(11,60) g
WHERE g % 3 = 0;

-- HORÁRIO (5 dias x 4 faixas = 20) --------------------------------------
INSERT INTO tb_horario (id_horario, semana_horario, hora_inicial, hora_final)
SELECT (d - 1) * 4 + s,
       (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta'])[d],
       (ARRAY['07:30','09:30','19:00','21:00']::time[])[s],
       (ARRAY['07:30','09:30','19:00','21:00']::time[])[s] + interval '1 hour 40 minutes'
FROM generate_series(1,5) d, generate_series(1,4) s;

-- PERÍODO LETIVO (2024.1 a 2026.2) ----------------------------------------
INSERT INTO tb_periodo_letivo (id_periodo_letivo, semestre_periodo_letivo, ano_periodo_letivo,
                               inicio_periodo_letivo, fim_periodo_letivo)
SELECT g,
       1 + (g - 1) % 2,
       2024 + (g - 1) / 2,
       make_date(2024 + (g - 1) / 2, CASE WHEN (g - 1) % 2 = 0 THEN 2 ELSE 8 END, 1),
       make_date(2024 + (g - 1) / 2, CASE WHEN (g - 1) % 2 = 0 THEN 6 ELSE 12 END,
                                     CASE WHEN (g - 1) % 2 = 0 THEN 30 ELSE 15 END)
FROM generate_series(1,6) g;

-- SALA (150: 30 por campus) -------------------------------------------------
INSERT INTO tb_sala (id_sala, id_campus, tipo_sala, capacidade_sala, codigo_sala, andar_sala)
SELECT g, 1 + (g - 1) % 5,
       (ARRAY['Sala de aula','Laboratório','Auditório'])[1 + g % 3],
       30 + (g % 5) * 10,
       'S' || lpad(g::text, 4, '0'),
       (g % 6)::text
FROM generate_series(1,150) g;

-- TURMA (1.800) ---------------------------------------------------------------
INSERT INTO tb_turma (id_turma, id_sala, id_periodo_letivo, id_horario, id_disciplina, id_professor)
SELECT g,
       1 + (g * 7) % 150,
       1 + g % 6,
       1 + (g * 3) % 20,
       1 + g % 60,
       1 + (g * 7) % 200
FROM generate_series(1,1800) g;

-- CALENDÁRIO (1 por campus x período = 30) e EVENTOS (4 cada = 120) ---------
INSERT INTO tb_calendario (id_calendario, id_campus, ano_calendario, semestre_calendario,
                           data_inicial, data_fim, descricao)
SELECT g, 1 + (g - 1) % 5, p.ano_periodo_letivo,
       p.ano_periodo_letivo || '.' || p.semestre_periodo_letivo,
       p.inicio_periodo_letivo, p.fim_periodo_letivo,
       'Calendário acadêmico ' || p.ano_periodo_letivo || '.' || p.semestre_periodo_letivo
FROM generate_series(1,30) g
JOIN tb_periodo_letivo p ON p.id_periodo_letivo = 1 + (g - 1) / 5;

INSERT INTO tb_eventos_calendario (id_eventos_calendario, id_calendario, titulo_evento,
                                   descricao_evento, data_inicial_evento, data_fim_evento,
                                   tipo_evento_feriado)
SELECT (c.id_calendario - 1) * 4 + e,
       c.id_calendario,
       (ARRAY['Início das aulas','Primeira avaliação (P1)','Recesso','Encerramento do semestre'])[e],
       (ARRAY['Abertura do semestre letivo','Semana de provas P1','Recesso acadêmico',
              'Último dia letivo'])[e],
       CASE e WHEN 1 THEN c.data_inicial
              WHEN 2 THEN c.data_inicial + 45
              WHEN 3 THEN c.data_inicial + 60
              ELSE c.data_fim END,
       CASE e WHEN 1 THEN c.data_inicial
              WHEN 2 THEN c.data_inicial + 51
              WHEN 3 THEN c.data_inicial + 62
              ELSE c.data_fim END,
       (ARRAY['Letivo','Avaliação','Feriado','Letivo'])[e]
FROM tb_calendario c, generate_series(1,4) e;

-- ENDEREÇO DO ALUNO (50.000, um por aluno) -------------------------------------
INSERT INTO tb_endereco_aluno (id_endereco_aluno, estado, cidade, cep, logradouro)
SELECT g,
       (ARRAY['DF','GO','SP','RJ','MG'])[1 + g % 5],
       (ARRAY['Brasília','Goiânia','São Paulo','Rio de Janeiro','Belo Horizonte'])[1 + g % 5],
       lpad((70000000 + g)::text, 8, '0'),
       'Rua ' || (1 + g % 300) || ', nº ' || (1 + g % 900)
FROM generate_series(1,50000) g;

-- ALUNO (50.000) ----------------------------------------------------------------
INSERT INTO tb_aluno (id_aluno, id_endereco_aluno, nome_aluno, cpf_aluno, email_aluno,
                      nascimento_aluno)
SELECT g, g,
       (ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Hugo','Isabela','João'])[1 + g % 10]
         || ' ' || (ARRAY['Silva','Souza','Costa','Pereira','Almeida','Rocha','Lima','Gomes'])[1 + g % 8]
         || ' ' || g,
       lpad(g::text, 11, '0'),
       'aluno' || g || '@iesb.edu.br',
       DATE '1990-01-01' + (g * 13 % 4500)
FROM generate_series(1,50000) g;

-- MATRÍCULA (50.000: 1 por aluno, no curso dele) ---------------------------------
-- Número no formato do trigger: AA + codigo_curso + sequencial de 4 dígitos,
-- reiniciando a cada ano/curso. Ex.: 241010001.
INSERT INTO tb_matricula (id_matricula, id_aluno, id_curso, data_inicio_matricula,
                          status_matricula, numero_matricula)
SELECT m.id, m.id, m.id_curso, m.dt, m.status,
       to_char(extract(year FROM m.dt)::int % 100, 'FM00') || c.codigo_curso
       || lpad((row_number() OVER (PARTITION BY extract(year FROM m.dt), m.id_curso
                                   ORDER BY m.id))::text, 4, '0')
FROM (SELECT g AS id,
             1 + g % 12 AS id_curso,
             DATE '2024-02-01' + (g * 11 % 1000) AS dt,
             (ARRAY['ATIVA','ATIVA','ATIVA','ATIVA','TRANCADA','CONCLUIDA','CANCELADA'])[1 + g % 7] AS status
      FROM generate_series(1,50000) g) m
JOIN tb_curso c ON c.id_curso = m.id_curso;

-- TURMA x MATRÍCULA (250.000: 5 turmas por matrícula) ----------------------------
-- k = 1..3 : disciplinas já finalizadas (nota final, aprovado/reprovado)
-- k = 4..5 : em andamento (nota parcial) ou trancadas, conforme a matrícula,
-- sempre em turmas do período atual (2026.2)
-- Aprovado = nota >= 5 e frequência >= 75.
INSERT INTO tb_turma_matricula (id_turma, id_matricula, nota, frequencia, situacao)
SELECT x.id_turma, x.id_matricula, x.nota, x.freq,
       CASE WHEN x.final THEN CASE WHEN x.nota >= 5 AND x.freq >= 75
                                   THEN 'APROVADO' ELSE 'REPROVADO' END
            WHEN x.mstatus IN ('TRANCADA','CANCELADA') THEN 'TRANCADO'
            ELSE 'CURSANDO' END
FROM (
  SELECT m.id_matricula,
         -- encerradas: turmas dos períodos 1..5 (já terminados)
         -- em andamento/trancadas: turmas do período 6 (2026.2, o atual)
         CASE WHEN k <= 3 OR m.status_matricula = 'CONCLUIDA'
                   THEN 1 + ((m.id_matricula * 31 + k * 97) % 1800)
                        + CASE WHEN (1 + ((m.id_matricula * 31 + k * 97) % 1800)) % 6 = 5
                               THEN 1 ELSE 0 END
              ELSE 6 * ((m.id_matricula * 31 + k * 97) % 300) + 5 END AS id_turma,
         m.status_matricula AS mstatus,
         (k <= 3 OR m.status_matricula = 'CONCLUIDA') AS final,
         CASE WHEN k <= 3 OR m.status_matricula = 'CONCLUIDA'
                   THEN round((2 + (random() + random() + random()) * 8 / 3)::numeric, 2)
              WHEN m.status_matricula IN ('TRANCADA','CANCELADA') THEN NULL
              ELSE round(((random() + random()) * 5)::numeric, 2) END AS nota,
         CASE WHEN k > 3 AND m.status_matricula IN ('TRANCADA','CANCELADA') THEN NULL
              ELSE round((70 + random() * 30)::numeric, 2) END AS freq
  FROM tb_matricula m, generate_series(1,5) k
) x;

-- USUÁRIOS DE DEMONSTRAÇÃO LIGADOS AOS DADOS (para testar o RLS com volume) --------
-- Alunos 1 e 2 e professor 1 passam a corresponder aos usuários criados no script 02.
UPDATE tb_aluno     SET usuario_bd = 'u_aluno' || id_aluno WHERE id_aluno IN (1, 2);
UPDATE tb_professor SET usuario_bd = 'u_prof1'             WHERE id_professor = 1;

-- HISTÓRICO / LOG (alimenta a partição por ano e o JSONB com GIN) ----------------
-- (1) criação de cada matrícula, na data de início
INSERT INTO tb_log_matricula (id_matricula, acao_log_matricula, data_ocorrido,
                              usuario_log_matricula, detalhe)
SELECT m.id_matricula, 'INSERT', m.data_inicio_matricula, 'carga_inicial',
       jsonb_build_object('tabela', 'tb_matricula', 'depois', to_jsonb(m))
FROM tb_matricula m;

-- (2) lançamento da nota final nas disciplinas encerradas (~150 dias após o início)
INSERT INTO tb_log_matricula (id_matricula, acao_log_matricula, data_ocorrido,
                              usuario_log_matricula, detalhe)
SELECT tm.id_matricula, 'UPDATE',
       LEAST(m.data_inicio_matricula + 150, current_date),
       'professor_' || t.id_professor,
       jsonb_build_object('tabela', 'tb_turma_matricula',
                          'antes',  jsonb_build_object('nota', NULL, 'situacao', 'CURSANDO'),
                          'depois', to_jsonb(tm))
FROM tb_turma_matricula tm
JOIN tb_matricula m ON m.id_matricula = tm.id_matricula
JOIN tb_turma     t ON t.id_turma     = tm.id_turma
WHERE tm.situacao IN ('APROVADO','REPROVADO');

-- Triggers voltam a ficar ativos para as próximas inserções
ALTER TABLE tb_matricula       ENABLE TRIGGER USER;
ALTER TABLE tb_turma_matricula ENABLE TRIGGER USER;

COMMIT;

ANALYZE;

-- CONFERÊNCIA -------------------------------------------------------------------------
SELECT 'campus' AS tabela, count(*) FROM tb_campus
UNION ALL SELECT 'curso',             count(*) FROM tb_curso
UNION ALL SELECT 'professor',         count(*) FROM tb_professor
UNION ALL SELECT 'disciplina',        count(*) FROM tb_disciplina
UNION ALL SELECT 'turma',             count(*) FROM tb_turma
UNION ALL SELECT 'aluno',             count(*) FROM tb_aluno
UNION ALL SELECT 'matricula',         count(*) FROM tb_matricula
UNION ALL SELECT 'turma_matricula',   count(*) FROM tb_turma_matricula
UNION ALL SELECT 'log_matricula',     count(*) FROM tb_log_matricula;

SELECT tableoid::regclass AS particao_do_log, count(*)
FROM tb_log_matricula GROUP BY 1 ORDER BY 1;

