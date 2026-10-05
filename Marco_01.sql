-- =========================
-- 1. CRIAÇÃO DO BANCO DE DADOS
-- =========================
CREATE DATABASE Projeto_universidade;

-- =========================
-- ENDERECO
-- =========================
CREATE TABLE tb_endereco (
    id_endereco SERIAL PRIMARY KEY,
    estado_endereco VARCHAR(50) NOT NULL,
    cidade_endereco VARCHAR(100) NOT NULL,
    pais_endereco VARCHAR(50) DEFAULT 'Brasil',
    cnpj_endereco VARCHAR(20) UNIQUE
);

-- =========================
-- CAMPUS
-- =========================
CREATE TABLE tb_campus (
    id_campus SERIAL PRIMARY KEY,
    nome_campus VARCHAR(100) NOT NULL,
    id_endereco INT NOT NULL,
    FOREIGN KEY (id_endereco) REFERENCES tb_endereco(id_endereco)
);

-- =========================
-- CURSO
-- =========================
CREATE TABLE tb_curso (
    id_curso SERIAL PRIMARY KEY,
    nome_curso VARCHAR(100) NOT NULL,
    grau_curso VARCHAR(50),
    chtotal_curso INT CHECK (chtotal_curso > 0),
    id_campus INT NOT NULL,
    FOREIGN KEY (id_campus) REFERENCES tb_campus(id_campus)
);

-- =========================
-- PROFESSOR
-- =========================
CREATE TABLE tb_professor (
    id_professor SERIAL PRIMARY KEY,
    nome_professor VARCHAR(100) NOT NULL,
    cpf_professor VARCHAR(14) UNIQUE NOT NULL,
    email_professor VARCHAR(100) UNIQUE NOT NULL,
    telefone_professor VARCHAR(20),
    data_admissao_professor DATE,
    titulacao_professor VARCHAR(50),
    id_campus INT,
    FOREIGN KEY (id_campus) REFERENCES tb_campus(id_campus)
);

-- =========================
-- DISCIPLINA
-- =========================
CREATE TABLE tb_disciplina (
    id_disciplina SERIAL PRIMARY KEY,
    codigo_disciplina VARCHAR(20) UNIQUE NOT NULL,
    nome_disciplina VARCHAR(100) NOT NULL,
    chpratica_disciplina INT CHECK (chpratica_disciplina >= 0),
    chteorica_disciplina INT CHECK (chteorica_disciplina >= 0)
);

-- =========================
-- REQUISITO
-- =========================
CREATE TABLE tb_requisito (
    id_requisito SERIAL PRIMARY KEY,
    id_disciplina INT NOT NULL,
    id_disciplina_requisito INT NOT NULL,
    FOREIGN KEY (id_disciplina) REFERENCES tb_disciplina(id_disciplina),
    FOREIGN KEY (id_disciplina_requisito) REFERENCES tb_disciplina(id_disciplina),
    UNIQUE (id_disciplina, id_disciplina_requisito)
);

-- =========================
-- TURMA
-- =========================
CREATE TABLE tb_turma (
    id_turma SERIAL PRIMARY KEY,
    codigo_turma VARCHAR(20),
    turno_turma VARCHAR(20),
    vagas_turma INT CHECK (vagas_turma > 0),
    id_disciplina INT NOT NULL,
    id_professor INT NOT NULL,
    FOREIGN KEY (id_disciplina) REFERENCES tb_disciplina(id_disciplina),
    FOREIGN KEY (id_professor) REFERENCES tb_professor(id_professor)
);

-- =========================
-- HORARIO
-- =========================
CREATE TABLE tb_horario (
    id_horario SERIAL PRIMARY KEY,
    dia_semana_horario VARCHAR(20),
    hora_inicio_horario TIME,
    hora_fim_horario TIME
);

-- RELAÇÃO N:N
CREATE TABLE tb_turma_horario (
    id_turma INT,
    id_horario INT,
    PRIMARY KEY (id_turma, id_horario),
    FOREIGN KEY (id_turma) REFERENCES tb_turma(id_turma),
    FOREIGN KEY (id_horario) REFERENCES tb_horario(id_horario)
);

-- =========================
-- ALUNO
-- =========================
CREATE TABLE tb_aluno (
    id_aluno SERIAL PRIMARY KEY,
    nome_aluno VARCHAR(100) NOT NULL,
    cpf_aluno VARCHAR(14) UNIQUE,
    email_aluno VARCHAR(100) UNIQUE,
    nascimento_aluno DATE,
    ingresso_aluno DATE,
    status_aluno VARCHAR(20),
    id_curso INT,
    FOREIGN KEY (id_curso) REFERENCES tb_curso(id_curso)
);

-- =========================
-- MATRICULA
-- =========================
CREATE TABLE tb_matricula (
    id_matricula SERIAL PRIMARY KEY,
    datainicio_matricula DATE DEFAULT CURRENT_DATE,
    status_matricula VARCHAR(20),
    id_aluno INT NOT NULL,
    id_turma INT NOT NULL,
    FOREIGN KEY (id_aluno) REFERENCES tb_aluno(id_aluno),
    FOREIGN KEY (id_turma) REFERENCES tb_turma(id_turma)
);

-- =========================
-- NOTA
-- =========================
CREATE TABLE tb_nota (
    id_nota SERIAL PRIMARY KEY,
    prova1_nota NUMERIC(5,2),
    prova2_nota NUMERIC(5,2),
    prova3_nota NUMERIC(5,2),
    frequencia_nota NUMERIC(5,2),
    situacao_nota VARCHAR(20),
    id_matricula INT UNIQUE,
    FOREIGN KEY (id_matricula) REFERENCES tb_matricula(id_matricula)
);
