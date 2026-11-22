-- =====================================================================
-- banco_de_dado.sql
-- Criação das tabelas da universidade

create table tb_disciplina(
	id_disciplina integer primary key,
	codigo_disciplina VARCHAR(30) not null,
	nome_disciplina VARCHAR(120) not null,
	hora_pratica_disciplina interval,
	hora_teorica_disciplina interval
);

create table tb_endereco_aluno(
	id_endereco_aluno integer primary key,
	estado VARCHAR(60) not null,
	cidade VARCHAR(60) not null,
	cep VARCHAR(9) not null,
	logradouro TEXT not null                     -- corrigido: longradouro
);

create table tb_endereco_campus(
	id_endereco_campus integer primary key,
	estado VARCHAR(60) not null,
	cidade VARCHAR(60) not null,
	cep VARCHAR(9) not null,
	logradouro TEXT not null                     -- corrigido: longradouro
);

create table tb_professor(
	id_professor integer primary key,
	nome_professor VARCHAR(120) not null,
	cpf_professor VARCHAR(11),
	email_professor varchar(150),
	registro_funcional VARCHAR(20) not null,    
	constraint uq_professor_cpf      unique (cpf_professor),
	constraint uq_professor_email    unique (email_professor),
	constraint uq_professor_registro unique (registro_funcional),
	constraint ck_professor_cpf      check (cpf_professor ~ '^[0-9]{11}$')
);

create table tb_horario(
	id_horario integer primary key,
	semana_horario text not null,
	hora_inicial time not null,
	hora_final time not null                     -- corrigido: hora_fina
);

create table tb_periodo_letivo(
	id_periodo_letivo integer primary key,
	semestre_periodo_letivo integer not null,
	ano_periodo_letivo integer not null,         -- corrigido: era DATE, agora inteiro (ex.: 2026)
	inicio_periodo_letivo date not null,
	fim_periodo_letivo date not null
);

create table tb_requisito(
	id_requisito integer primary key,
	id_disciplina integer references tb_disciplina(id_disciplina),
	requisito_diciplina VARCHAR(70)
);

create table tb_aluno(
	id_aluno integer primary key,
	id_endereco_aluno integer references tb_endereco_aluno (id_endereco_aluno),
	nome_aluno VARCHAR(120) not null,
	cpf_aluno VARCHAR(11) not null,
	email_aluno VARCHAR(150) not null,
	nascimento_aluno DATE,                       -- corrigido: nacimento_aluno
	constraint uq_aluno_cpf   unique (cpf_aluno),
	constraint uq_aluno_email unique (email_aluno),
	constraint ck_aluno_cpf   check (cpf_aluno ~ '^[0-9]{11}$')
);

create table tb_campus(
	id_campus integer primary key,
	id_endereco_campus integer references tb_endereco_campus(id_endereco_campus),
	nome_campus VARCHAR(120) not null,
	cnpj_endereco varchar(14) unique not null
);

create table tb_calendario(
	id_calendario integer primary key,
	id_campus integer references tb_campus(id_campus),
	ano_calendario integer,
	semestre_calendario text,
	data_inicial date,                           -- corrigido: data_inical
	data_fim date,
	descricao text
);

create table tb_eventos_calendario(
	id_eventos_calendario integer primary key,   -- corrigido: id_envetos_calendario
	id_calendario integer references tb_calendario(id_calendario),
	titulo_evento VARCHAR(70),
	descricao_evento VARCHAR(120),
	data_inicial_evento date,
	data_fim_evento date,
	tipo_evento_feriado VARCHAR(60)
);

create table tb_sala(
	id_sala integer primary key,
	id_campus integer references tb_campus(id_campus),
	tipo_sala VARCHAR(60) not NULL,
	capacidade_sala integer not null,
	codigo_sala VARCHAR(30) not null,
	andar_sala VARCHAR(15),
	unique(codigo_sala)
);

create table tb_curso(
	id_curso integer primary key,
	id_campus integer references tb_campus(id_campus),
	nome_curso text not null,                    -- corrigido: nome_cusro
	grau_curso TEXT not null
);

create table tb_curso_disciplina(
	id_curso integer references tb_curso(id_curso),
	id_disciplina integer references  tb_disciplina(id_disciplina ),
	carga_horario_total_curso integer not null
);

create table tb_matricula(
	id_matricula integer primary key,
	id_aluno integer references tb_aluno(id_aluno),
	id_curso integer references tb_curso(id_curso),
	Data_inicio_matricula date not null,
	status_matricula VARCHAR(60)
);


create table tb_turma(
	id_turma integer primary key,
	id_sala integer references tb_sala(id_sala),
	id_periodo_letivo integer references tb_periodo_letivo(id_periodo_letivo),
	id_horario integer references tb_horario(id_horario),
	id_disciplina integer references tb_disciplina(id_disciplina),
	id_professor integer references tb_professor(id_professor)
);

create table tb_turma_matricula(
	id_turma integer references tb_turma(id_turma),
	id_matricula integer references tb_matricula(id_matricula),
	nota numeric(5,2),
	frequencia numeric(5,2),
	situacao varchar(60)
);

