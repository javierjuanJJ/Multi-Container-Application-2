#!/usr/bin/env bash
#
# Copia de seguridad de MongoDB en un tarball (.tar.gz), lista para subir a
# Cloudflare R2.
#
#   ./scripts/mongo-backup.sh
#
# Se ejecuta en el host donde corre el contenedor de MongoDB (el Droplet o tu
# maquina local). No hay que instalar nada: mongodump y tar son los que ya trae
# la imagen oficial de MongoDB.
#
# Entrada (todas opcionales):
#   MONGO_CONTAINER  nombre/id del contenedor. Por defecto se toma el primero
#                    con la etiqueta com.docker.compose.service=mongo.
#   MONGO_DATABASE   base de datos a volcar (por defecto: todos)
#   BACKUP_DIR       carpeta de salida (por defecto: $HOME/backups)
#
# Contrato de salida:
#   stdout -> una unica linea con la ruta absoluta del tarball. El workflow la
#             captura con:
#               remote=$(ssh host 'bash -s' < scripts/mongo-backup.sh)
#   stderr -> todo el progreso (es lo que se ve en los logs)
#
# La contrasena de MongoDB no aparece en ningun `ps`: viaja por el stdin del
# shell del contenedor, de modo que solo mongodump la ve, y dentro del propio
# contenedor. En el servidor no se escribe en ningun fichero.
set -euo pipefail

log() { printf '[mongo-backup] %s\n' "$*" >&2; }
die() { printf '[mongo-backup] ERROR: %s\n' "$*" >&2; exit 1; }

# Escapa un valor como literal POSIX para el shell del contenedor.
# (No se usa `printf %q` porque genera $'...', que el sh de Ubuntu no entiende.)
shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

command -v docker > /dev/null 2>&1 || die "docker no esta en el PATH"

MONGO_DATABASE="${MONGO_DATABASE:-todos}"
BACKUP_DIR="${BACKUP_DIR:-${HOME:-/tmp}/backups}"
case "$BACKUP_DIR" in
  /*) ;;
  *) BACKUP_DIR="$PWD/$BACKUP_DIR" ;;
esac
mkdir -p "$BACKUP_DIR"
[ -w "$BACKUP_DIR" ] || die "no se puede escribir en ${BACKUP_DIR}"

# --- localizar el contenedor -------------------------------------------------
if [ -z "${MONGO_CONTAINER:-}" ]; then
  MONGO_CONTAINER="$(docker ps \
    --filter 'label=com.docker.compose.service=mongo' \
    --format '{{.ID}}' | head -n 1)"
fi
[ -n "$MONGO_CONTAINER" ] || die "no hay ningun contenedor de MongoDB en marcha (define MONGO_CONTAINER)"

# --- credenciales ------------------------------------------------------------
# Se leen del entorno del propio contenedor: no viajan por ssh ni por argv.
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

# --- nombres y limpieza ------------------------------------------------------
ts="$(date -u +%Y%m%dT%H%M%SZ)"
name="${MONGO_DATABASE}-${ts}.tar.gz"
dest="${BACKUP_DIR}/${name}"
container_tar="/tmp/${name}"
mongo_version="$(docker exec "$MONGO_CONTAINER" mongod --version 2>/dev/null | head -n 1 || true)"
[ -n "$mongo_version" ] || mongo_version="desconocida"

cleanup() {
  status=$?
  if [ -n "${MONGO_CONTAINER:-}" ] && [ -n "${container_tar:-}" ]; then
    docker exec "$MONGO_CONTAINER" rm -f "$container_tar" > /dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ] && [ -n "${dest:-}" ]; then
    rm -f "$dest"
  fi
  exit "$status"
}
trap cleanup EXIT

# --- volcar dentro del contenedor -------------------------------------------
# El script remoto viaja por stdin: por eso la contrasena no aparece en el argv
# de `docker exec` (visible con `ps` en el servidor) ni en el de `ssh`.
log "Volcando ${MONGO_DATABASE} desde el contenedor ${MONGO_CONTAINER} (${mongo_version})"
docker exec -i "$MONGO_CONTAINER" sh -s <<EOF
set -eu
exec 1>&2

work="\$(mktemp -d)"
trap 'rm -rf "\$work"' EXIT

mongodump $auth_args --db $(shquote "$MONGO_DATABASE") --out "\$work/dump"

{
  echo created_utc=$(shquote "$ts")
  echo database=$(shquote "$MONGO_DATABASE")
  echo container=$(shquote "$MONGO_CONTAINER")
  echo mongo_version=$(shquote "$mongo_version")
} > "\$work/manifest.txt"

tar -czf $(shquote "$container_tar") -C "\$work" dump manifest.txt
EOF

# --- traer el tarball al host ------------------------------------------------
docker cp "${MONGO_CONTAINER}:${container_tar}" "$dest"

listing="$(tar -tzf "$dest")" || die "el tarball generado no se puede leer"
grep -qx 'manifest.txt' <<< "$listing" || die "el tarball no incluye manifest.txt"

entries="$(wc -l <<< "$listing" | tr -d ' ')"
size="$(du -h "$dest" | cut -f1)"
log "OK: ${dest} (${size}, ${entries} entradas)"

printf '%s\n' "$dest"
