#!/usr/bin/env bash
# =====================================================================
# backup_restore.sh - backup e restauração reproduzíveis (PostgreSQL)
#
# Uso:
#   ./backup_restore.sh backup
#   ./backup_restore.sh restore <pasta_do_backup> [banco_destino]
#   ./backup_restore.sh verify  <banco_origem> <banco_restaurado>
#
# Variáveis (com padrão):
#   PGHOST=localhost  PGPORT=5432  DB_NAME=universidade
#   BACKUP_USER=role_backup   (BYPASSRLS, só leitura)
#   ADMIN_USER=postgres       (cria o banco na restauração)
#   BACKUP_DIR=./backups      RETENCAO_DIAS=14
# Senhas: use ~/.pgpass (chmod 600) ou PGPASSWORD. Nunca no script.
#
# Agendamento sugerido (cron, todo dia às 02:00):
#   0 2 * * * /caminho/backup_restore.sh backup >> /var/log/bkp_uni.log 2>&1
# =====================================================================
set -euo pipefail

: "${PGHOST:=localhost}" "${PGPORT:=5432}" "${DB_NAME:=universidade}"
: "${BACKUP_USER:=role_backup}" "${ADMIN_USER:=postgres}"
: "${BACKUP_DIR:=./backups}" "${RETENCAO_DIAS:=14}"

conexao_backup() { echo -h "$PGHOST" -p "$PGPORT" -U "$BACKUP_USER" --no-password; }
conexao_admin()  { echo -h "$PGHOST" -p "$PGPORT" -U "$ADMIN_USER"  --no-password; }

# ---------------------------------------------------------------------
backup() {
  local ts dir
  ts=$(date +%Y%m%d_%H%M%S)
  dir="$BACKUP_DIR/$ts"
  mkdir -p "$dir"

  echo "[backup] dump do banco $DB_NAME (formato custom, comprimido)..."
  # shellcheck disable=SC2046
  pg_dump $(conexao_backup) -d "$DB_NAME" -Fc -f "$dir/$DB_NAME.dump"

  echo "[backup] dump dos papéis (roles) e grants globais..."
  # Sem isso, a restauração perde roles/permissões e o RLS deixa de funcionar.
  # shellcheck disable=SC2046
  pg_dumpall $(conexao_backup) --globals-only --no-role-passwords -f "$dir/globals.sql"

  echo "[backup] validando se o dump é legível..."
  pg_restore --list "$dir/$DB_NAME.dump" > /dev/null

  echo "[backup] gerando checksums..."
  (cd "$dir" && sha256sum "$DB_NAME.dump" globals.sql > SHA256SUMS)

  echo "[backup] removendo backups com mais de $RETENCAO_DIAS dias..."
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENCAO_DIAS" -exec rm -rf {} +

  echo "[backup] OK -> $dir"
}

# ---------------------------------------------------------------------
restore() {
  local dir="${1:?informe a pasta do backup}"
  local destino="${2:-${DB_NAME}_restore}"

  echo "[restore] conferindo integridade (checksums)..."
  (cd "$dir" && sha256sum -c SHA256SUMS)

  echo "[restore] recriando banco $destino..."
  # shellcheck disable=SC2046
  dropdb   $(conexao_admin) --if-exists "$destino"
  # shellcheck disable=SC2046
  createdb $(conexao_admin) "$destino"

  echo "[restore] restaurando papéis (erros 'already exists' são esperados)..."
  # shellcheck disable=SC2046
  psql $(conexao_admin) -d postgres -v ON_ERROR_STOP=0 -q -f "$dir/globals.sql" > /dev/null || true

  echo "[restore] restaurando dados..."
  # shellcheck disable=SC2046
  pg_restore $(conexao_admin) -d "$destino" --exit-on-error --single-transaction \
             "$dir/$DB_NAME.dump"

  echo "[restore] OK -> banco $destino"
  echo "[restore] lembrete: as senhas dos papéis não vão no backup (--no-role-passwords);"
  echo "          defina-as com ALTER ROLE ... PASSWORD ..."
}

# ---------------------------------------------------------------------
# Resumo comparável: contagem de linhas por tabela + nº de policies RLS
resumo() {
  # shellcheck disable=SC2046
  psql -X -At $(conexao_admin) -d "$1" <<'SQL'
SELECT 'tabela:' || table_name || '=' ||
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name),
                           false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
UNION ALL
SELECT 'policies_rls=' || count(*) FROM pg_policies WHERE schemaname = 'public'
UNION ALL
SELECT 'tabelas_com_rls=' || count(*) FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND c.relrowsecurity
UNION ALL
SELECT 'triggers=' || count(*) FROM pg_trigger WHERE NOT tgisinternal
ORDER BY 1;
SQL
}

verify() {
  local origem="${1:?banco de origem}" restaurado="${2:?banco restaurado}"
  echo "[verify] comparando $origem x $restaurado..."
  if diff <(resumo "$origem") <(resumo "$restaurado"); then
    echo "[verify] OK: mesma contagem de linhas, policies RLS e triggers."
  else
    echo "[verify] FALHA: diferenças acima." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------
case "${1:-}" in
  backup)  backup ;;
  restore) shift; restore "$@" ;;
  verify)  shift; verify "$@" ;;
  *) echo "Uso: $0 {backup | restore <pasta> [banco_destino] | verify <origem> <restaurado>}" >&2
     exit 1 ;;
esac
