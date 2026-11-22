-- =====================================================================
-- 01_alteracoes_banco.sql
-- Ajustes na estrutura do banco da universidade

BEGIN;

-- ---------------------------------------------------------------------
-- 1. LIGAÇÃO USUÁRIO DO BANCO <-> ALUNO/PROFESSOR (base do RLS)
-- ---------------------------------------------------------------------
ALTER TABLE tb_aluno     ADD COLUMN usuario_bd text UNIQUE;
ALTER TABLE tb_professor ADD COLUMN usuario_bd text UNIQUE;

-- ---------------------------------------------------------------------
-- 2. CURSO: código de 3 dígitos usado na matrícula (AA + CCC + NNNN)
-- ---------------------------------------------------------------------
ALTER TABLE tb_curso
  ADD COLUMN codigo_curso char(3),
  ADD CONSTRAINT uq_curso_codigo UNIQUE (codigo_curso),
  ADD CONSTRAINT ck_curso_codigo CHECK (codigo_curso ~ '^[0-9]{3}$');
-- Depois de preencher os cursos existentes:
--   ALTER TABLE tb_curso ALTER COLUMN codigo_curso SET NOT NULL;

-- ---------------------------------------------------------------------
-- 3. MATRÍCULA: número gerado automaticamente + integridade
-- ---------------------------------------------------------------------
ALTER TABLE tb_matricula
  ALTER COLUMN id_aluno               SET NOT NULL,
  ALTER COLUMN id_curso               SET NOT NULL,
  ALTER COLUMN data_inicio_matricula  SET DEFAULT current_date,
  ALTER COLUMN status_matricula       SET DEFAULT 'ATIVA',
  ALTER COLUMN status_matricula       SET NOT NULL,
  ADD COLUMN numero_matricula varchar(9),
  ADD CONSTRAINT uq_matricula_numero      UNIQUE (numero_matricula),
  ADD CONSTRAINT uq_matricula_aluno_curso UNIQUE (id_aluno, id_curso),
  ADD CONSTRAINT ck_matricula_numero      CHECK (numero_matricula ~ '^[0-9]{9}$'),
  ADD CONSTRAINT ck_matricula_status      CHECK (status_matricula IN ('ATIVA','TRANCADA','CANCELADA','CONCLUIDA'));

-- acelera a busca do último sequencial por prefixo (AA+CCC)
CREATE INDEX idx_matricula_numero_prefixo
  ON tb_matricula (numero_matricula text_pattern_ops);

-- ---------------------------------------------------------------------
-- 4. TABELAS DE LIGAÇÃO: chaves primárias, NOT NULL e checks
-- ---------------------------------------------------------------------
ALTER TABLE tb_turma_matricula
  ALTER COLUMN id_turma     SET NOT NULL,
  ALTER COLUMN id_matricula SET NOT NULL,
  ALTER COLUMN situacao     SET DEFAULT 'CURSANDO',
  ADD CONSTRAINT pk_turma_matricula PRIMARY KEY (id_turma, id_matricula),
  ADD CONSTRAINT ck_tm_nota       CHECK (nota BETWEEN 0 AND 10),
  ADD CONSTRAINT ck_tm_frequencia CHECK (frequencia BETWEEN 0 AND 100),
  ADD CONSTRAINT ck_tm_situacao   CHECK (situacao IN ('CURSANDO','APROVADO','REPROVADO','TRANCADO'));

ALTER TABLE tb_curso_disciplina
  ALTER COLUMN id_curso      SET NOT NULL,
  ALTER COLUMN id_disciplina SET NOT NULL,
  ADD CONSTRAINT pk_curso_disciplina PRIMARY KEY (id_curso, id_disciplina);

-- índices nas FKs usadas pelo RLS e pelas views
CREATE INDEX idx_tm_matricula    ON tb_turma_matricula (id_matricula);
CREATE INDEX idx_turma_professor ON tb_turma (id_professor);
CREATE INDEX idx_matricula_aluno ON tb_matricula (id_aluno);

-- ---------------------------------------------------------------------
-- 5. GERAÇÃO AUTOMÁTICA DO NÚMERO DE MATRÍCULA (sem tabela contador)
--    Formato: AA + código do curso + sequencial de 4 dígitos
--    Ex.: ingresso 2026, curso 101, 1º aluno -> 261010001
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_gerar_numero_matricula() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_codigo   char(3);
  v_ano      integer;
  v_prefixo  text;
  v_seq      integer;
BEGIN
  -- trava a linha do curso: inserções do mesmo curso entram em fila,
  -- evitando que duas matrículas leiam o mesmo "último sequencial"
  SELECT codigo_curso INTO v_codigo
  FROM tb_curso
  WHERE id_curso = NEW.id_curso
  FOR NO KEY UPDATE;

  IF v_codigo IS NULL THEN
    RAISE EXCEPTION 'Curso % sem codigo_curso definido', NEW.id_curso;
  END IF;

  NEW.data_inicio_matricula := COALESCE(NEW.data_inicio_matricula, current_date);
  v_ano     := EXTRACT(YEAR FROM NEW.data_inicio_matricula)::integer;
  v_prefixo := to_char(v_ano % 100, 'FM00') || v_codigo;          -- ex.: '26101'

  SELECT COALESCE(MAX(substr(numero_matricula, 6)::integer), 0) + 1
    INTO v_seq
    FROM tb_matricula
   WHERE numero_matricula LIKE (v_prefixo || '%');

  IF v_seq > 9999 THEN
    RAISE EXCEPTION 'Limite de 9999 matrículas atingido para o prefixo %', v_prefixo;
  END IF;

  NEW.numero_matricula := v_prefixo || lpad(v_seq::text, 4, '0');
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_matricula_numero
BEFORE INSERT ON tb_matricula
FOR EACH ROW
WHEN (NEW.numero_matricula IS NULL)
EXECUTE FUNCTION fn_gerar_numero_matricula();

-- o número da matrícula nunca pode ser alterado depois de gerado
CREATE OR REPLACE FUNCTION fn_numero_matricula_imutavel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'numero_matricula não pode ser alterado';
END;
$$;

CREATE TRIGGER trg_matricula_numero_imutavel
BEFORE UPDATE OF numero_matricula ON tb_matricula
FOR EACH ROW
WHEN (OLD.numero_matricula IS DISTINCT FROM NEW.numero_matricula)
EXECUTE FUNCTION fn_numero_matricula_imutavel();

-- ---------------------------------------------------------------------
-- 6. BÔNUS: HISTÓRICO/LOG PARTICIONADO POR ANO + JSONB COM ÍNDICE GIN
-- ---------------------------------------------------------------------
-- Sem FK para tb_matricula de propósito: o log deve sobreviver a qualquer
-- alteração na matrícula. A PK inclui data_ocorrido (exigência do
-- particionamento: a chave de partição precisa fazer parte da PK).
CREATE TABLE tb_log_matricula (
  id_log_matricula       bigint GENERATED ALWAYS AS IDENTITY,
  id_matricula           integer     NOT NULL,
  acao_log_matricula     varchar(20) NOT NULL,
  data_ocorrido          date        NOT NULL DEFAULT current_date,
  usuario_log_matricula  varchar(63) NOT NULL DEFAULT session_user,
  detalhe                jsonb,
  PRIMARY KEY (id_log_matricula, data_ocorrido)
) PARTITION BY RANGE (data_ocorrido);

-- cria a partição de um ano (rodar todo fim de ano para o ano seguinte)
CREATE OR REPLACE FUNCTION fn_criar_particao_log(p_ano integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS %I PARTITION OF tb_log_matricula FOR VALUES FROM (%L) TO (%L)',
    'tb_log_matricula_' || p_ano,
    make_date(p_ano, 1, 1),
    make_date(p_ano + 1, 1, 1));
END;
$$;

SELECT fn_criar_particao_log(y) FROM generate_series(2024, 2030) AS y;

-- rede de segurança: datas fora das partições anuais não quebram o INSERT
CREATE TABLE IF NOT EXISTS tb_log_matricula_default
  PARTITION OF tb_log_matricula DEFAULT;

-- índices (criados no pai e propagados para todas as partições)
CREATE INDEX idx_log_matricula_id    ON tb_log_matricula (id_matricula, data_ocorrido);
CREATE INDEX idx_log_detalhe_gin     ON tb_log_matricula USING GIN (detalhe jsonb_path_ops);

-- o log é imutável: ninguém altera nem apaga registros de auditoria
CREATE OR REPLACE FUNCTION fn_log_imutavel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'tb_log_matricula é somente-inserção (% bloqueado)', TG_OP;
END;
$$;

CREATE TRIGGER trg_log_imutavel
BEFORE UPDATE OR DELETE ON tb_log_matricula
FOR EACH ROW EXECUTE FUNCTION fn_log_imutavel();

-- ---------------------------------------------------------------------
-- 7. AUDITORIA AUTOMÁTICA (alimenta o log em JSONB)
--    SECURITY DEFINER: quem altera não precisa de permissão no log.
--    Por isso usa session_user (current_user seria o dono da função).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_auditar_matricula() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id  integer;
  v_det jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_id  := NEW.id_matricula;
    v_det := jsonb_build_object('tabela', TG_TABLE_NAME, 'depois', to_jsonb(NEW));
  ELSIF TG_OP = 'UPDATE' THEN
    v_id  := NEW.id_matricula;
    v_det := jsonb_build_object('tabela', TG_TABLE_NAME,
                                'antes', to_jsonb(OLD), 'depois', to_jsonb(NEW));
  ELSE
    v_id  := OLD.id_matricula;
    v_det := jsonb_build_object('tabela', TG_TABLE_NAME, 'antes', to_jsonb(OLD));
  END IF;

  INSERT INTO tb_log_matricula (id_matricula, acao_log_matricula, usuario_log_matricula, detalhe)
  VALUES (v_id, TG_OP, session_user, v_det);

  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_auditoria_matricula
AFTER INSERT OR UPDATE OR DELETE ON tb_matricula
FOR EACH ROW EXECUTE FUNCTION fn_auditar_matricula();

CREATE TRIGGER trg_auditoria_turma_matricula
AFTER INSERT OR UPDATE OR DELETE ON tb_turma_matricula
FOR EACH ROW EXECUTE FUNCTION fn_auditar_matricula();

COMMIT;

