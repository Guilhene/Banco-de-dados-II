-- =====================================================================
-- Marco 2 — 00_dados.sql
-- Dados sintéticos para dar volume ao banco. Requer o esquema do Marco 1.
-- Idempotente apenas em banco vazio: rode após `docker compose down -v`.
-- =====================================================================

-- ENDEREÇO / CAMPUS ---------------------------------------------------
INSERT INTO tb_endereco (estado_endereco, cidade_endereco, cnpj_endereco)
SELECT (ARRAY['DF','GO','SP','RJ','MG'])[g], (ARRAY['Brasília','Goiânia','São Paulo','Rio de Janeiro','Belo Horizonte'])[g],
       lpad(g::text, 14, '0')
FROM generate_series(1,5) g;

INSERT INTO tb_campus (nome_campus, id_endereco)
SELECT 'Campus ' || cidade_endereco, id_endereco FROM tb_endereco;

-- CURSO (12 cursos distribuídos pelos campi) ---------------------------
INSERT INTO tb_curso (nome_curso, grau_curso, chtotal_curso, id_campus)
SELECT 'Curso ' || g, (ARRAY['Bacharelado','Licenciatura','Tecnólogo'])[1 + g % 3],
       2400 + (g % 4) * 400, 1 + g % 5
FROM generate_series(1,12) g;

-- PROFESSOR (200) ------------------------------------------------------
INSERT INTO tb_professor (nome_professor, cpf_professor, email_professor, telefone_professor,
                          data_admissao_professor, titulacao_professor, id_campus)
SELECT 'Professor ' || g, lpad(g::text, 11, '0'), 'prof' || g || '@iesb.br',
       '61 9' || lpad((10000000 + g)::text, 8, '0'),
       DATE '2005-01-01' + (g * 37 % 7000),
       (ARRAY['Especialista','Mestre','Doutor'])[1 + g % 3],
       1 + g % 5
FROM generate_series(1,200) g;

-- DISCIPLINA (60) e REQUISITO ------------------------------------------
INSERT INTO tb_disciplina (codigo_disciplina, nome_disciplina, chpratica_disciplina, chteorica_disciplina)
SELECT 'DISC' || lpad(g::text, 3, '0'), 'Disciplina ' || g, (g % 3) * 20, 40 + (g % 2) * 20
FROM generate_series(1,60) g;

INSERT INTO tb_requisito (id_disciplina, id_disciplina_requisito)
SELECT g, g - 10 FROM generate_series(11,60) g WHERE g % 3 = 0;

-- HORÁRIO (5 dias x 4 faixas) -----------------------------------------
INSERT INTO tb_horario (dia_semana_horario, hora_inicio_horario, hora_fim_horario)
SELECT d, h, h + interval '1 hour 40 minutes'
FROM unnest(ARRAY['Segunda','Terça','Quarta','Quinta','Sexta']) d,
     unnest(ARRAY['07:30','09:30','19:00','21:00']::time[]) h;

-- TURMA (1.800) ---------------------------------------------------------
INSERT INTO tb_turma (codigo_turma, turno_turma, vagas_turma, id_disciplina, id_professor)
SELECT 'T' || lpad(g::text, 5, '0'),
       (ARRAY['Manhã','Noite'])[1 + g % 2],
       40 + (g % 5) * 10,
       1 + g % 60,
       1 + (g * 7) % 200
FROM generate_series(1,1800) g;

INSERT INTO tb_turma_horario (id_turma, id_horario)
SELECT t, 1 + (t * 3) % 20 FROM generate_series(1,1800) t
UNION
SELECT t, 1 + (t * 3 + 7) % 20 FROM generate_series(1,1800) t;

-- ALUNO (50.000) --------------------------------------------------------
INSERT INTO tb_aluno (nome_aluno, cpf_aluno, email_aluno, nascimento_aluno, ingresso_aluno, status_aluno, id_curso)
SELECT (ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Hugo','Isabela','João'])[1 + g % 10]
         || ' ' || (ARRAY['Silva','Souza','Costa','Pereira','Almeida','Rocha','Lima','Gomes'])[1 + g % 8]
         || ' ' || g,
       lpad(g::text, 11, '0'), 'aluno' || g || '@iesb.edu.br',
       DATE '1990-01-01' + (g * 13 % 4500),
       DATE '2020-01-01' + (g * 11 % 2400),
       (ARRAY['ativo','ativo','ativo','ativo','trancado','formado','cancelado'])[1 + g % 7],
       1 + g % 12
FROM generate_series(1,50000) g;

-- MATRÍCULA (~250 mil): 5 matrículas por aluno ---------------------------
INSERT INTO tb_matricula (datainicio_matricula, status_matricula, id_aluno, id_turma)
SELECT DATE '2024-02-01' + (a * k % 700),
       CASE WHEN k <= 3 THEN 'concluida' WHEN k = 4 THEN 'ativa' ELSE
            (ARRAY['ativa','trancada','cancelada'])[1 + (a % 3)] END,
       a,
       1 + ((a * 31 + k * 97) % 1800)
FROM generate_series(1,50000) a, generate_series(1,5) k;

-- NOTA (uma por matrícula; quem está 'ativa' ainda não tem prova3) -------
INSERT INTO tb_nota (prova1_nota, prova2_nota, prova3_nota, frequencia_nota, situacao_nota, id_matricula)
SELECT round((random()*10)::numeric, 2),
       round((random()*10)::numeric, 2),
       CASE WHEN m.status_matricula = 'concluida' THEN round((random()*10)::numeric, 2) END,
       round((55 + random()*45)::numeric, 2),
       'cursando',
       m.id_matricula
FROM tb_matricula m;

-- Situação final das concluídas: média >= 5 e frequência >= 75 aprova.
UPDATE tb_nota n
SET situacao_nota = CASE WHEN (prova1_nota + prova2_nota + prova3_nota) / 3 >= 5
                          AND frequencia_nota >= 75 THEN 'aprovado' ELSE 'reprovado' END
FROM tb_matricula m
WHERE m.id_matricula = n.id_matricula AND m.status_matricula = 'concluida';

ANALYZE;