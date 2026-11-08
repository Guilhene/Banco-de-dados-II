-- =====================================================================
-- Marco 2 — 01_views.sql
-- 3 views + 1 materialized view.
--
-- Convenções do modelo (usadas nas views e no seed):
--   status_matricula : 'ativa' | 'concluida' | 'trancada' | 'cancelada'
--   situacao_nota    : 'cursando' | 'aprovado' | 'reprovado'
--   média da disciplina = média aritmética das provas já lançadas
--   (prova NULL = ainda não aplicada, não conta como zero).
-- =====================================================================

-- ---------------------------------------------------------------------
-- VIEW 1 — vw_historico_aluno
-- Histórico acadêmico: uma linha por aluno x disciplina cursada.
-- Uso: secretaria / portal do aluno (SELECT ... WHERE id_aluno = ?).
-- Motivo de ser view: junta 7 tabelas e calcula a média; evita repetir
-- esse JOIN em toda tela e esconde detalhes do esquema.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_historico_aluno AS
SELECT a.id_aluno,
       a.nome_aluno,
       c.nome_curso,
       d.codigo_disciplina,
       d.nome_disciplina,
       t.codigo_turma,
       p.nome_professor,
       m.id_matricula,
       m.datainicio_matricula,
       m.status_matricula,
       n.prova1_nota,
       n.prova2_nota,
       n.prova3_nota,
       round( (COALESCE(n.prova1_nota,0) + COALESCE(n.prova2_nota,0) + COALESCE(n.prova3_nota,0))
              / NULLIF( (n.prova1_nota IS NOT NULL)::int
                      + (n.prova2_nota IS NOT NULL)::int
                      + (n.prova3_nota IS NOT NULL)::int, 0), 2) AS media_nota,
       n.frequencia_nota,
       n.situacao_nota
FROM tb_aluno      a
JOIN tb_curso      c ON c.id_curso      = a.id_curso
JOIN tb_matricula  m ON m.id_aluno      = a.id_aluno
JOIN tb_turma      t ON t.id_turma      = m.id_turma
JOIN tb_disciplina d ON d.id_disciplina = t.id_disciplina
JOIN tb_professor  p ON p.id_professor  = t.id_professor
LEFT JOIN tb_nota  n ON n.id_matricula  = m.id_matricula;

-- ---------------------------------------------------------------------
-- VIEW 2 — vw_ocupacao_turma
-- Ocupação de cada turma: vagas, matriculados ativos, vagas livres, %.
-- Uso: período de matrícula (coordenação vê turmas lotadas/vazias).
-- Precisa ser view comum (não materializada): o dado muda a cada matrícula.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ocupacao_turma AS
SELECT t.id_turma,
       t.codigo_turma,
       d.codigo_disciplina,
       d.nome_disciplina,
       p.nome_professor,
       t.turno_turma,
       t.vagas_turma,
       count(m.id_matricula) FILTER (WHERE m.status_matricula = 'ativa')            AS matriculados_ativos,
       t.vagas_turma - count(m.id_matricula) FILTER (WHERE m.status_matricula = 'ativa') AS vagas_livres,
       round(100.0 * count(m.id_matricula) FILTER (WHERE m.status_matricula = 'ativa')
             / t.vagas_turma, 1)                                                    AS pct_ocupacao
FROM tb_turma t
JOIN tb_disciplina d ON d.id_disciplina = t.id_disciplina
JOIN tb_professor  p ON p.id_professor  = t.id_professor
LEFT JOIN tb_matricula m ON m.id_turma  = t.id_turma
GROUP BY t.id_turma, d.id_disciplina, p.id_professor;

-- ---------------------------------------------------------------------
-- VIEW 3 — vw_carga_professor
-- Carga de cada professor: nº de turmas, carga horária total (teórica +
-- prática da disciplina de cada turma) e alunos com matrícula ativa.
-- Uso: coordenação / RH para distribuir turmas.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_carga_professor AS
SELECT p.id_professor,
       p.nome_professor,
       p.titulacao_professor,
       c.nome_campus,
       COALESCE(t.qtd_turmas, 0)      AS qtd_turmas,
       COALESCE(t.ch_total, 0)        AS carga_horaria_total,
       COALESCE(a.alunos_ativos, 0)   AS alunos_ativos
FROM tb_professor p
LEFT JOIN tb_campus c ON c.id_campus = p.id_campus
LEFT JOIN (SELECT t.id_professor,
                  count(*) AS qtd_turmas,
                  sum(d.chpratica_disciplina + d.chteorica_disciplina) AS ch_total
           FROM tb_turma t
           JOIN tb_disciplina d ON d.id_disciplina = t.id_disciplina
           GROUP BY t.id_professor) t ON t.id_professor = p.id_professor
LEFT JOIN (SELECT t.id_professor, count(*) AS alunos_ativos
           FROM tb_turma t
           JOIN tb_matricula m ON m.id_turma = t.id_turma AND m.status_matricula = 'ativa'
           GROUP BY t.id_professor) a ON a.id_professor = p.id_professor;

-- ---------------------------------------------------------------------
-- MATERIALIZED VIEW — mv_desempenho_curso
-- Indicadores por curso: alunos, matrículas concluídas, média geral,
-- frequência média e taxa de aprovação.
-- É a consulta mais cara do sistema (agrega TODAS as notas e matrículas)
-- e é consumida por painel gerencial, não por transação operacional.
-- ---------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_desempenho_curso;
CREATE MATERIALIZED VIEW mv_desempenho_curso AS
SELECT c.id_curso,
       c.nome_curso,
       cp.nome_campus,
       count(DISTINCT a.id_aluno)                                         AS qtd_alunos,
       count(*) FILTER (WHERE n.situacao_nota IN ('aprovado','reprovado')) AS qtd_disciplinas_concluidas,
       round(avg( (COALESCE(n.prova1_nota,0)+COALESCE(n.prova2_nota,0)+COALESCE(n.prova3_nota,0))/3.0 )
             FILTER (WHERE n.situacao_nota IN ('aprovado','reprovado')), 2) AS media_geral,
       round(avg(n.frequencia_nota)
             FILTER (WHERE n.situacao_nota IN ('aprovado','reprovado')), 2) AS frequencia_media,
       round(100.0 * count(*) FILTER (WHERE n.situacao_nota = 'aprovado')
             / NULLIF(count(*) FILTER (WHERE n.situacao_nota IN ('aprovado','reprovado')), 0), 1) AS taxa_aprovacao_pct,
       now()                                                              AS atualizado_em
FROM tb_curso c
JOIN tb_campus cp      ON cp.id_campus = c.id_campus
LEFT JOIN tb_aluno a   ON a.id_curso   = c.id_curso
LEFT JOIN tb_matricula m ON m.id_aluno = a.id_aluno
LEFT JOIN tb_nota n    ON n.id_matricula = m.id_matricula
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
--     * o cálculo percorre ~250 mil notas; refazê-lo a cada INSERT/UPDATE
--       (via trigger) puniria exatamente as transações de matrícula e de
--       lançamento de nota, que são o caminho crítico do sistema;
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
