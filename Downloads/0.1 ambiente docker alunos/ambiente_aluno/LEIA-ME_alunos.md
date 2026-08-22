# Ambiente de trabalho — Banco de Dados II (CCO072)

**IESB · 2026/2 · Prof. Rodrigo Gonçalves**

Este é o ambiente onde você vai desenvolver o **Projeto Acadêmico IESB** ao longo do semestre. Ele sobe um PostgreSQL 17 com o banco `matricula` **vazio** — você constrói o esquema a partir do **Modelo Lógico** que acompanha o enunciado do projeto.

---

## Pré-requisito

Ter o **Docker Desktop** instalado (Windows, macOS ou Linux). Nada mais precisa ser instalado — o PostgreSQL e o pgAdmin vêm dentro dos contêineres.

---

## Subindo o ambiente

Dentro desta pasta, no terminal:

```bash
docker compose up -d
```

Na primeira vez o Docker baixa as imagens (leva alguns minutos). Quando terminar, você tem:

| Serviço | Endereço | Credenciais |
|---|---|---|
| **PostgreSQL** | `localhost:5432` | usuário `bd2` · senha `bd2` · base `matricula` |
| **pgAdmin** | `http://localhost:8080` | login `admin@iesb.br` · senha `admin` |

Você pode usar o pgAdmin (no navegador) ou conectar o **DBeaver** com os mesmos dados.

---

## Comandos do dia a dia

| Comando | O que faz |
|---|---|
| `docker compose up -d` | liga o ambiente |
| `docker compose down` | desliga, **mantendo** seus dados |
| `docker compose down -v` | desliga e **apaga tudo** (recomeça do zero) |
| `docker compose ps` | mostra se os serviços estão no ar |
| `docker compose logs -f` | acompanha o que está acontecendo |

Seus dados ficam salvos num volume do Docker entre um `up` e outro. Só o `down -v` apaga.

---

## Por onde começar

1. Suba o ambiente e conecte-se à base `matricula` pelo pgAdmin ou DBeaver.
2. Abra o **Modelo Lógico** (o diagrama entregue com o enunciado do projeto).
3. Escreva o **DDL** — as instruções `CREATE TABLE`, com tipos, chaves e restrições — traduzindo o diagrama para SQL. **Isto é o Marco 1 do projeto.**
4. Rode seu script no banco e verifique se as tabelas foram criadas sem erro.

Guarde seu SQL num repositório **Git** desde o início — o histórico de commits faz parte da avaliação.

---

## Dica

Trabalhe com um arquivo `.sql` versionado, não digitando direto no pgAdmin. Assim você tem histórico, consegue recriar o banco quando quiser (`down -v` e rodar o script de novo) e entrega um artefato reproduzível — que é o que o projeto pede.

## Se algo der errado

| Sintoma | O que verificar |
|---|---|
| `port is already allocated` | outro serviço usa a porta 5432 ou 8080; feche-o ou ajuste a porta no `docker-compose.yml` |
| pgAdmin não abre | espere ~30s após o `up`; o pgAdmin demora mais que o banco para iniciar |
| esqueci tudo e quero recomeçar | `docker compose down -v` apaga o banco e permite começar limpo |
