-- =====================================================================
-- Marco 2 — 01_views.sql   (adaptado ao esquema atual do banco)
-- 3 views + 1 materialized view.
--
-- Ordem: instalar_tudo.sql  ->  ESTE arquivo  ->  02_indices.sql
--
-- Convenções do modelo (usadas nas views):
--   status_matricula : 'ATIVA' | 'CONCLUIDA' | 'TRANCADA' | 'CANCELADA'
--   situacao (tb_turma_matricula): 'CURSANDO' | 'APROVADO' | 'REPROVADO' | 'TRANCADO'
--   nota única por disciplina (tb_turma_matricula.nota, 0 a 10).
--   vagas da turma = capacidade da sala (tb_sala.capacidade_sala).
--   turno da turma = derivado da hora inicial do horário (tb_horario).
--   codigo_turma = ano.semestre-disciplina-id (ex.: 2026.2-DISC005-0497).
--
-- Mapa do que mudou em relação ao esquema antigo (Marco 1):
--   tb_nota                      -> tb_turma_matricula (nota, frequencia, situacao)
--   tb_matricula.id_turma        -> tb_turma_matricula (vínculo matrícula x turma)
--   tb_aluno.id_curso            -> tb_matricula.id_curso
--   tb_aluno.status_aluno        -> tb_matricula.status_matricula
--   tb_turma.vagas_turma         -> tb_sala.capacidade_sala
--   datainicio_matricula         -> data_inicio_matricula
--   chpratica/chteorica (int)    -> hora_pratica/hora_teorica (interval)
-- =====================================================================
SET search_path TO public;

DROP MATERIALIZED VIEW IF EXISTS mv_desempenho_curso;
DROP VIEW IF EXISTS vw_historico_aluno, vw_ocupacao_turma, vw_carga_professor;

-- ---------------------------------------------------------------------
-- VIEW 1 — vw_historico_aluno
-- Histórico acadêmico: uma linha por aluno x disciplina cursada.
-- Uso: secretaria / portal do aluno (SELECT ... WHERE id_aluno = ?).
-- Motivo de ser view: junta 8 tabelas; evita repetir esse JOIN em toda
-- tela e esconde detalhes do esquema.
-- security_invoker: a view respeita o RLS de quem consulta (um aluno só
-- veria as próprias linhas, caso receba GRANT nela).
-- ---------------------------------------------------------------------
CREATE VIEW vw_historico_aluno WITH (security_invoker = true) AS
SELECT a.id_aluno,
       a.nome_aluno,
       c.nome_curso,
       m.id_matricula,
       m.numero_matricula,
       m.data_inicio_matricula,
       m.status_matricula,
       d.codigo_disciplina,
       d.nome_disciplina,
       t.id_turma,
       pl.ano_periodo_letivo || '.' || pl.semestre_periodo_letivo
         || '-' || d.codigo_disciplina || '-' || lpad(t.id_turma::text, 4, '0') AS codigo_turma,
       p.nome_professor,
       tm.nota,
       tm.frequencia,
       tm.situacao
FROM tb_aluno            a
JOIN tb_matricula        m  ON m.id_aluno        = a.id_aluno
JOIN tb_curso            c  ON c.id_curso        = m.id_curso
JOIN tb_turma_matricula  tm ON tm.id_matricula   = m.id_matricula
JOIN tb_turma            t  ON t.id_turma        = tm.id_turma
JOIN tb_disciplina       d  ON d.id_disciplina   = t.id_disciplina
JOIN tb_professor        p  ON p.id_professor    = t.id_professor
JOIN tb_periodo_letivo   pl ON pl.id_periodo_letivo = t.id_periodo_letivo;

-- ---------------------------------------------------------------------
-- VIEW 2 — vw_ocupacao_turma
-- Ocupação de cada turma: vagas (capacidade da sala), cursando, vagas
-- livres, %. Uso: período de matrícula (coordenação vê turmas lotadas).
-- Precisa ser view comum (não materializada): o dado muda a cada matrícula.
-- ---------------------------------------------------------------------
CREATE VIEW vw_ocupacao_turma AS
SELECT t.id_turma,
       pl.ano_periodo_letivo || '.' || pl.semestre_periodo_letivo
         || '-' || d.codigo_disciplina || '-' || lpad(t.id_turma::text, 4, '0') AS codigo_turma,
       d.codigo_disciplina,
       d.nome_disciplina,
       p.nome_professor,
       CASE WHEN h.hora_inicial < TIME '12:00' THEN 'Manhã'
            WHEN h.hora_inicial < TIME '18:00' THEN 'Tarde'
            ELSE 'Noite' END                                                   AS turno_turma,
       s.capacidade_sala                                                       AS vagas_turma,
       count(tm.id_matricula) FILTER (WHERE tm.situacao = 'CURSANDO')          AS matriculados_ativos,
       s.capacidade_sala - count(tm.id_matricula) FILTER (WHERE tm.situacao = 'CURSANDO') AS vagas_livres,
       round(100.0 * count(tm.id_matricula) FILTER (WHERE tm.situacao = 'CURSANDO')
             / NULLIF(s.capacidade_sala, 0), 1)                                AS pct_ocupacao
FROM tb_turma t
JOIN tb_disciplina       d  ON d.id_disciplina      = t.id_disciplina
JOIN tb_professor        p  ON p.id_professor       = t.id_professor
JOIN tb_sala             s  ON s.id_sala            = t.id_sala
JOIN tb_horario          h  ON h.id_horario         = t.id_horario
JOIN tb_periodo_letivo   pl ON pl.id_periodo_letivo = t.id_periodo_letivo
LEFT JOIN tb_turma_matricula tm ON tm.id_turma      = t.id_turma
GROUP BY t.id_turma, d.id_disciplina, p.id_professor, s.id_sala, h.id_horario, pl.id_periodo_letivo;

-- ---------------------------------------------------------------------
-- VIEW 3 — vw_carga_professor
-- Carga de cada professor: nº de turmas, carga horária total (teórica +
-- prática da disciplina de cada turma, em horas) e alunos cursando.
-- Uso: coordenação / RH para distribuir turmas.
-- ---------------------------------------------------------------------
CREATE VIEW vw_carga_professor AS
SELECT p.id_professor,
       p.nome_professor,
       p.registro_funcional,
       COALESCE(t.qtd_turmas, 0)      AS qtd_turmas,
       COALESCE(t.ch_total, 0)        AS carga_horaria_total,
       COALESCE(a.alunos_ativos, 0)   AS alunos_ativos
FROM tb_professor p
LEFT JOIN (SELECT t.id_professor,
                  count(*) AS qtd_turmas,
                  round(EXTRACT(EPOCH FROM sum(COALESCE(d.hora_pratica_disciplina, interval '0')
                                             + COALESCE(d.hora_teorica_disciplina, interval '0'))) / 3600)::int AS ch_total
           FROM tb_turma t
           JOIN tb_disciplina d ON d.id_disciplina = t.id_disciplina
           GROUP BY t.id_professor) t ON t.id_professor = p.id_professor
LEFT JOIN (SELECT t.id_professor, count(*) AS alunos_ativos
           FROM tb_turma t
           JOIN tb_turma_matricula tm ON tm.id_turma = t.id_turma AND tm.situacao = 'CURSANDO'
           GROUP BY t.id_professor) a ON a.id_professor = p.id_professor;

-- ---------------------------------------------------------------------
-- MATERIALIZED VIEW — mv_desempenho_curso
-- Indicadores por curso: alunos, disciplinas concluídas, média geral,
-- frequência média e taxa de aprovação.
-- É a consulta mais cara do sistema (agrega TODAS as notas e matrículas)
-- e é consumida por painel gerencial, não por transação operacional.
-- Obs.: materialized view não tem RLS; só o dono/papéis com GRANT leem.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_desempenho_curso AS
SELECT c.id_curso,
       c.nome_curso,
       cp.nome_campus,
       count(DISTINCT m.id_aluno)                                            AS qtd_alunos,
       count(*) FILTER (WHERE tm.situacao IN ('APROVADO','REPROVADO'))       AS qtd_disciplinas_concluidas,
       round(avg(tm.nota)       FILTER (WHERE tm.situacao IN ('APROVADO','REPROVADO')), 2) AS media_geral,
       round(avg(tm.frequencia) FILTER (WHERE tm.situacao IN ('APROVADO','REPROVADO')), 2) AS frequencia_media,
       round(100.0 * count(*) FILTER (WHERE tm.situacao = 'APROVADO')
             / NULLIF(count(*) FILTER (WHERE tm.situacao IN ('APROVADO','REPROVADO')), 0), 1) AS taxa_aprovacao_pct,
       now()                                                                 AS atualizado_em
FROM tb_curso c
JOIN tb_campus cp                ON cp.id_campus  = c.id_campus
LEFT JOIN tb_matricula m         ON m.id_curso    = c.id_curso
LEFT JOIN tb_turma_matricula tm  ON tm.id_matricula = m.id_matricula
GROUP BY c.id_curso, cp.id_campus
WITH DATA;

-- Índice ÚNICO: pré-requisito para REFRESH ... CONCURRENTLY.
CREATE UNIQUE INDEX uq_mv_desempenho_curso ON mv_desempenho_curso (id_curso);

-- ---------------------------------------------------------------------
-- POLÍTICA DE ATUALIZAÇÃO da mv_desempenho_curso
--
--   Quando : 1x por dia, de madrugada (ex.: 03:00), e 1x extra manual
--            logo após o fechamento de notas do semestre.
--   Como   : REFRESH MATERIALIZED VIEW CONCURRENTLY mv_desempenho_curso;
--
--   Por que 1x/dia e não em tempo real:
--     * indicadores gerenciais (média, aprovação) não mudam o suficiente
--       em horas para alterar uma decisão; defasagem de até 24 h é aceitável;
--     * o cálculo percorre ~250 mil vínculos turma x matrícula; refazê-lo a
--       cada INSERT/UPDATE (via trigger) puniria exatamente as transações
--       de matrícula e de lançamento de nota, que são o caminho crítico;
--     * de madrugada a carga é mínima.
--   Por que CONCURRENTLY:
--     * o refresh comum toma lock exclusivo e bloqueia leitores do painel
--       durante o recálculo; o CONCURRENTLY deixa o painel lendo a versão
--       antiga até a nova ficar pronta (custo: mais lento e exige o índice
--       único acima).
--   Agendamento: o Postgres não tem agendador nativo. Opções: `pg_cron`
--     (SELECT cron.schedule('0 3 * * *', 'REFRESH MATERIALIZED VIEW
--     CONCURRENTLY mv_desempenho_curso');) onde a extensão existir, ou
--     cron do SO / job do pgAdmin com psql. A coluna atualizado_em informa
--     ao consumidor a idade do dado.
--   As views 1–3 NÃO são materializadas de propósito: refletem a
--     matrícula em tempo real, e são consultadas por chave (um aluno, uma
--     turma), o que os índices do arquivo 02 tornam barato.
-- ---------------------------------------------------------------------
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_desempenho_curso;
