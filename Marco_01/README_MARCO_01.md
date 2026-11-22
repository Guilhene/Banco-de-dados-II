# Marco 1 --- Sistema de Gerenciamento Acadêmico

## O que o projeto faz

O projeto implementa a estrutura inicial de um banco de dados acadêmico
para gerenciar informações de uma instituição de ensino.

O banco organiza dados relacionados a:

-   **Campi e endereços:** localização dos campi da instituição.
-   **Cursos e disciplinas:** cursos oferecidos, disciplinas e seus
    pré-requisitos.
-   **Alunos e professores:** dados cadastrais e endereços dos alunos.
-   **Matrículas:** vínculo dos alunos com os cursos, com geração
    automática do número de matrícula.
-   **Turmas e horários:** disciplinas ofertadas, professores
    responsáveis, salas e períodos letivos.
-   **Calendário acadêmico:** períodos letivos e eventos de cada campus.
-   **Notas e frequência:** vínculo entre matrículas e turmas, com
    registro de nota, frequência e situação.
-   **Auditoria:** registro das operações realizadas nas matrículas, com
    histórico armazenado em log.

O projeto também configura permissões específicas para alunos,
professores, secretaria e auditores. A segurança por linha (RLS)
restringe quais registros cada perfil pode consultar ou alterar. Há
ainda regras de integridade, geração automática e proteção do número de
matrícula, além de registros de auditoria.

Os dados incluídos em `Dados_01.sql` são sintéticos e servem para
popular o banco e permitir testes. A carga cria, entre outros registros,
5 campi, 12 cursos, 200 professores, 60 disciplinas, 1.800 turmas,
50.000 alunos e 50.000 matrículas.

## Requisitos

-   PostgreSQL **15 ou superior**.
-   Acesso ao banco com um usuário proprietário ou com permissões
    administrativas suficientes para criar tabelas, funções, triggers,
    papéis, permissões e políticas de segurança.
-   Um cliente SQL, como DBeaver ou `psql`.

## Como executar

Execute os arquivos **na ordem abaixo**, todos na mesma base de dados:

  -----------------------------------------------------------------------
  Ordem                   Arquivo                 Finalidade
  ----------------------- ----------------------- -----------------------
  1                       `Esquema_00.sql`        Cria as tabelas e os
                                                  relacionamentos do
                                                  banco acadêmico.

  2                       `Alteração.sql`         Adiciona campos,
                                                  restrições, índices,
                                                  geração automática do
                                                  número de matrícula e
                                                  estrutura de auditoria.

  3                       `Segurança.sql`         Cria os papéis e
                                                  usuários de
                                                  demonstração, configura
                                                  permissões, RLS e a
                                                  view de histórico
                                                  escolar; executa testes
                                                  de segurança.

  4                       `Dados_01.sql`          Insere os dados
                                                  sintéticos para
                                                  utilização e testes do
                                                  sistema.
  -----------------------------------------------------------------------

### Pelo DBeaver

1.  Abra o DBeaver e conecte-se ao PostgreSQL.
2.  Selecione a base de dados que será utilizada.
3.  Abra `Esquema_00.sql` e execute o script completo.
4.  Repita o procedimento, na ordem, para `Alteração.sql`,
    `Segurança.sql` e `Dados_01.sql`.
5.  Para executar o arquivo inteiro, utilize **Executar script
    (Alt+X)**. O atalho **Ctrl+Enter** executa apenas o comando
    atual/selecionado.

### Pelo terminal com psql

Com o PostgreSQL em execução, abra o terminal na pasta que contém os
arquivos e execute os comandos abaixo, substituindo `NOME_DO_BANCO`,
`USUARIO` e os dados de conexão pelos valores do seu ambiente:

``` bash
psql -h localhost -p 5432 -U USUARIO -d NOME_DO_BANCO -v ON_ERROR_STOP=1 -f Esquema_00.sql
psql -h localhost -p 5432 -U USUARIO -d NOME_DO_BANCO -v ON_ERROR_STOP=1 -f Alteração.sql
psql -h localhost -p 5432 -U USUARIO -d NOME_DO_BANCO -v ON_ERROR_STOP=1 -f Segurança.sql
psql -h localhost -p 5432 -U USUARIO -d NOME_DO_BANCO -v ON_ERROR_STOP=1 -f Dados_01.sql
```

Se o PostgreSQL estiver configurado em outra porta, ajuste o valor
`5432`.

## Observações importantes

-   Execute os quatro arquivos na ordem indicada e na mesma base de
    dados.
-   `Dados_01.sql` deve ser executado como proprietário do banco ou
    usuário com permissões administrativas e em uma base que já tenha
    passado pelos três scripts anteriores.
-   A carga de dados é destinada a uma base vazia. Não execute
    `Dados_01.sql` novamente sobre uma base já populada, pois os
    identificadores e registros podem gerar conflitos de chave única.
-   O script `Segurança.sql` cria usuários de demonstração com senhas de
    exemplo. Altere essas senhas antes de utilizar o banco em qualquer
    ambiente real.
-   Os testes de demonstração presentes em `Segurança.sql` são
    executados em uma transação finalizada com `ROLLBACK`, portanto os
    registros usados nesses testes não permanecem no banco.
-   A execução desses scripts configura o banco de dados; não há, nestes
    arquivos, uma aplicação com interface gráfica para iniciar.
