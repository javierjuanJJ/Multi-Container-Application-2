#!/usr/bin/env bash
#
# Descarga una copia de seguridad de MongoDB desde Cloudflare R2 y la restaura
# en el contenedor de MongoDB (el complemento de mongo-backup.sh).
#
#   ./scripts/mongo-restore.sh --list        # que hay en R2
#   ./scripts/mongo-restore.sh --dry-run     # descarga y verifica sin tocar datos
#   ./scripts/mongo-restore.sh               # restaura la copia mas reciente
#   ./scripts/mongo-restore.sh <clave>       # restaura una copia concreta
#
# Se ejecuta en el host donde corre el contenedor de MongoDB (el mismo en el
# que corre mongo-backup.sh). Solo hace falta docker: si no esta instalada la
# CLI de AWS se usa la imagen amazon/aws-cli por Docker.
#
# Entrada:
#   R2_ACCOUNT_ID      Account ID de Cloudflare (R2 -> Details)
#   R2_ACCESS_KEY_ID   id de una API token de R2 con Object Read & Write
#   R2_SECRET_ACCESS_KEY  secreto de esa API token
#   R2_BUCKET_NAME     por defecto: todos-backups
#   R2_PREFIX          por defecto: backups/mongo
#   MONGO_CONTAINER    contenedor de destino (por defecto: el de compose)
#   MONGO_DATABASE     base de datos destino (por defecto: todos)
#
# La restauracion sustituye las colecciones existentes (--drop). Sin terminal
# de interaccion hay que confirmarlo con --yes (por ejemplo:
#   ssh host 'bash -s -- --yes' < scripts/mongo-restore.sh).
set -euo pipefail

log() { printf '[mongo-restore] %s\n' "$*" >&2; }
die() { printf '[mongo-restore] ERROR: %s\n' "$*" >&2; exit 1; }

shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

usage() {
  cat <<'USAGE'
Uso: mongo-restore.sh [--list | --dry-run | [--yes] [clave]]

  --list      lista las copias disponibles en R2 y termina
  --dry-run   descarga y verifica la copia sin restaurar nada
  --yes, -y   no pregunta antes de sustituir los datos actuales
  <clave>     clave concreta del bucket (por defecto: la mas reciente)
USAGE
}

list_only=0 dry_run=0 assume_yes=0 key=""
for arg in "$@"; do
  case "$arg" in
    --list) list_only=1 ;;
    --dry-run) dry_run=1 ;;
    --yes | -y) assume_yes=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) printf 'opcion desconocida: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$key" ] || die "solo se admite una copia a la vez"
      key="$arg"
      ;;
  esac
done

command -v docker > /dev/null 2>&1 || die "docker no esta en el PATH"
command -v tar > /dev/null 2>&1 || die "tar no esta en el PATH"

R2_ACCOUNT_ID="${R2_ACCOUNT_ID:?define R2_ACCOUNT_ID}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?define R2_ACCESS_KEY_ID}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?define R2_SECRET_ACCESS_KEY}"
R2_BUCKET_NAME="${R2_BUCKET_NAME:-todos-backups}"
R2_PREFIX="${R2_PREFIX:-backups/mongo}"
MONGO_DATABASE="${MONGO_DATABASE:-todos}"

# --- carpeta de trabajo ------------------------------------------------------
WORKDIR="$(mktemp -d)"
# El fallback por Docker monta WORKDIR en /r2 y trabaja dentro de el, asi que
# todos los ficheros se referencian relativos a este directorio.
cd "$WORKDIR"

MONGO_CONTAINER="${MONGO_CONTAINER:-}"
remote_dir=""

cleanup() {
  status=$?
  if [ -n "${MONGO_CONTAINER:-}" ] && [ -n "${remote_dir:-}" ]; then
    docker exec "$MONGO_CONTAINER" rm -rf "$remote_dir" > /dev/null 2>&1 || true
  fi
  if [ -n "${WORKDIR:-}" ]; then
    rm -rf "$WORKDIR"
  fi
  exit "$status"
}
trap cleanup EXIT

# --- cliente S3 contra Cloudflare R2 -----------------------------------------
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto

if command -v aws > /dev/null 2>&1; then
  aws_r2() { aws --endpoint-url "$R2_ENDPOINT" "$@"; }
else
  log "aws CLI no instalado: uso la imagen amazon/aws-cli via Docker"
  aws_r2() {
    docker run --rm \
      -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
      -v "${WORKDIR}:/r2" -w /r2 \
      amazon/aws-cli --endpoint-url "$R2_ENDPOINT" "$@"
  }
fi

prefix="${R2_PREFIX:+${R2_PREFIX%/}/}"
bucket_path="s3://${R2_BUCKET_NAME}/${prefix}"

if [ "$list_only" -eq 1 ]; then
  log "Copias en ${bucket_path}"
  aws_r2 s3 ls "$bucket_path"
  exit 0
fi

# --- elegir la copia ---------------------------------------------------------
if [ -z "$key" ]; then
  log "Buscando la copia mas reciente en ${bucket_path}"
  key="$(aws_r2 s3api list-objects-v2 \
    --bucket "$R2_BUCKET_NAME" \
    --prefix "$prefix" \
    --query 'sort_by(Contents,&LastModified)[-1].Key' \
    --output text)"
  [ -n "$key" ] && [ "$key" != "None" ] || die "no hay copias en ${bucket_path}"
fi

# --- descargar y verificar ---------------------------------------------------
file="$(basename "$key")"
log "Descargando s3://${R2_BUCKET_NAME}/${key}"
aws_r2 s3 cp "s3://${R2_BUCKET_NAME}/${key}" "$file" > /dev/null

tar -tzf "$file" > /dev/null || die "el tarball esta corrupto: ${file}"
mkdir -p extract
tar -xzf "$file" -C extract
[ -d extract/dump ] || die "el tarball no contiene el directorio dump/"

manifest_db=""
if [ -f extract/manifest.txt ]; then
  log "manifest.txt:"
  sed 's/^/    /' extract/manifest.txt >&2
  manifest_db="$(sed -n 's/^database=//p' extract/manifest.txt | head -n 1)"
  if [ -n "$manifest_db" ] && [ "$manifest_db" != "$MONGO_DATABASE" ]; then
    log "AVISO: la copia es de '${manifest_db}' y el destino es '${MONGO_DATABASE}'"
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  log "dry-run: el tarball es valido, no se restaura nada"
  exit 0
fi

# --- localizar el contenedor -------------------------------------------------
if [ -z "$MONGO_CONTAINER" ]; then
  MONGO_CONTAINER="$(docker ps \
    --filter 'label=com.docker.compose.service=mongo' \
    --format '{{.ID}}' | head -n 1)"
fi
[ -n "$MONGO_CONTAINER" ] || die "no hay ningun contenedor de MongoDB en marcha (define MONGO_CONTAINER)"

# --- confirmar ---------------------------------------------------------------
if [ "$assume_yes" -ne 1 ]; then
  if [ -t 0 ]; then
    printf '[mongo-restore] Se sustituiran las colecciones de %s en %s. Continuar? [y/N] ' \
      "$MONGO_DATABASE" "$MONGO_CONTAINER" >&2
    read -r reply
    case "$reply" in
      y | Y | s | S | si | si* | yes) ;;
      *) die "restauracion cancelada" ;;
    esac
  else
    die "sin terminal interactiva: repite con --yes para confirmar la restauracion"
  fi
fi

# --- credenciales ------------------------------------------------------------
db_user="$(docker exec "$MONGO_CONTAINER" printenv MONGO_INITDB_ROOT_USERNAME 2>/dev/null || true)"
db_pass="$(docker exec "$MONGO_CONTAINER" printenv MONGO_INITDB_ROOT_PASSWORD 2>/dev/null || true)"

case "${db_user}${db_pass}" in
  *$'\n'*|*$'\r'*) die "las credenciales de MongoDB no pueden contener saltos de linea" ;;
esac

auth_args=""
if [ -n "$db_user" ]; then
  auth_args="$(printf '%s %s %s ' \
    --username "$(shquote "$db_user")" \
    --password "$(shquote "$db_pass")" \
    --authenticationDatabase admin)"
fi

# --- copiar el dump al contenedor -------------------------------------------
ts="$(date -u +%Y%m%dT%H%M%SZ)"
remote_dir="/tmp/mongorestore-${ts}"
log "Copiando el dump al contenedor ${MONGO_CONTAINER}"
docker exec "$MONGO_CONTAINER" mkdir -p "$remote_dir"
docker cp "extract/dump" "${MONGO_CONTAINER}:${remote_dir}/dump"

# Mismo esquema que el backup: mongodump --db X --out d genera d/X/*.bson.
# Si la base del tarball es la de destino se restaura de forma explicita; si no,
# mongorestore deduce la base de cada subdirectorio y se respeta el nombre
# original de la copia.
db_args=""
target_dir="${remote_dir}/dump"
restored_db="$manifest_db"
if [ -d "extract/dump/${MONGO_DATABASE}" ]; then
  db_args="--db $(shquote "$MONGO_DATABASE")"
  target_dir="${remote_dir}/dump/${MONGO_DATABASE}"
  restored_db="$MONGO_DATABASE"
fi

if [ -n "$restored_db" ]; then
  log "Restaurando en ${restored_db} (las colecciones existentes se sustituyen)"
else
  log "Restaurando en la base original del tarball (las colecciones existentes se sustituyen)"
fi
docker exec -i "$MONGO_CONTAINER" sh -s <<EOF
set -eu
exec 1>&2

mongorestore $auth_args $db_args --drop --dir $(shquote "$target_dir")
EOF

# --- comprobar ---------------------------------------------------------------
if [ -n "$restored_db" ]; then
  docker exec -i "$MONGO_CONTAINER" sh -s <<EOF
set -eu
exec 1>&2

mongosh --quiet $auth_args --eval $(shquote "const d = db.getSiblingDB(\"${restored_db}\"); const cs = d.getCollectionNames(); const n = cs.reduce((t, c) => t + d.getCollection(c).countDocuments(), 0); print('restaurado: ' + cs.length + ' colecciones, ' + n + ' documentos');")
EOF
else
  log "AVISO: no se pudo determinar la base de destino; comprueba el vol manualmente"
fi

log "OK: restauracion completada desde s3://${R2_BUCKET_NAME}/${key}"
