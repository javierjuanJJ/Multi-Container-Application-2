#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Blue-Green Deployment para el stack de produccion (docker-compose.prod.yml)
#
#   ./scripts/blue-green.sh deploy MY_USER/todos-api:sha-abc123
#
# Que hace un `deploy`:
#
#   1. lee el color activo en nginx/upstream/active.conf (blue o green)
#   2. escribe la imagen nueva en el slot INACTIVO y la levanta con
#      `docker compose up -d --wait`: mientras tanto nadie recibe trafico
#   3. comprueba la salud del slot nuevo dos veces: healthcheck del contenedor
#      y /health servido desde la propia red de nginx
#   4. si todo va bien, escribe active.conf con el color nuevo, valida con
#      `nginx -t` y recarga con `nginx -s reload` -> la conmutacion no corta
#      ni una peticion (las conexiones en vuelo las termina nginx)
#   5. verifica /health por el puerto publico y, opcionalmente, el CRUD
#   6. deja el color anterior EN PIE como blanco de rollback inmediato
#
# Si algo falla en 2-5 el trafico NO se mueve: sigue en el color activo. Solo
# se reverte la conmutacion si el fallo aparece despues de escribir active.conf
# (rollback automatico en el mismo proceso).
#
# MongoDB es unico para los dos slots: mismo volumen, cero perdida de datos.
#
# Uso:
#   blue-green.sh deploy <imagen> [--stop-previous] [--no-verify]
#   blue-green.sh switch <blue|green>     conmuta a un color ya desplegado
#   blue-green.sh rollback                vuelve al color anterior
#   blue-green.sh retire [color]          para el color que no sirve trafico
#   blue-green.sh status                  color activo, salud e imagen de cada slot
#   blue-green.sh verify [--crud]         /health y CRUD por el puerto publico
#   blue-green.sh validate                solo valida compose (CI/Ansible)
#   blue-green.sh init                    crea el fichero de estado si falta
#   blue-green.sh help
#
# Variables de entorno:
#   DEPLOY_DIR     directorio del stack (por defecto: el del compose)
#   COMPOSE_FILE   docker-compose.prod.yml
#   ENV_FILE       .env.production
#   WAIT_TIMEOUT   segundos de espera del healthcheck (180)
#   VERIFY_RETRIES intentos de verificacion post-conmutacion (10)
# ---------------------------------------------------------------------------
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-.env.production}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
VERIFY_RETRIES="${VERIFY_RETRIES:-10}"

# --- salida -----------------------------------------------------------------
if [[ -t 1 ]]; then
  C_INFO=$'\033[1;34m' C_WARN=$'\033[1;33m' C_ERR=$'\033[1;31m' C_OK=$'\033[1;32m' C_OFF=$'\033[0m'
else
  C_INFO='' C_WARN='' C_ERR='' C_OK='' C_OFF=''
fi
info() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()   { printf '%s OK%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%sAVISO%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

# --- localizacion -----------------------------------------------------------
# Vale ejecutado desde el repo (scripts/blue-green.sh) o copiado al servidor
# (/opt/todos/blue-green.sh): el directorio del stack es el que contiene el
# fichero de compose, sea este o su padre.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${DEPLOY_DIR:-}" ]]; then
  :
elif [[ -f "${script_dir}/${COMPOSE_FILE}" ]]; then
  DEPLOY_DIR="$script_dir"
elif [[ -f "${script_dir}/../${COMPOSE_FILE}" ]]; then
  DEPLOY_DIR="$(cd "${script_dir}/.." && pwd)"
else
  DEPLOY_DIR="$PWD"
fi
DEPLOY_DIR="$(cd "$DEPLOY_DIR" && pwd)"

UPSTREAM_DIR="${DEPLOY_DIR}/nginx/upstream"
UPSTREAM_FILE="${UPSTREAM_DIR}/active.conf"
STATE_FILE="${DEPLOY_DIR}/.blue-green-state"

cd "$DEPLOY_DIR"

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

# --- utilidades -------------------------------------------------------------
other_color() { if [[ "$1" == "blue" ]]; then echo green; else echo blue; fi; }

read_active() {
  # El color activo es el que dice el fichero que nginx esta sirviendo.
  local color=""
  if [[ -f "$UPSTREAM_FILE" ]]; then
    color="$(grep -Eo 'api-(blue|green)' "$UPSTREAM_FILE" | head -n1 | cut -d- -f2 || true)"
  fi
  printf '%s' "${color:-blue}"
}

state_get() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep -E "^${1}=" "$STATE_FILE" | tail -n1 | cut -d= -f2- || true
}

state_set() {
  local key=$1 value=$2
  touch "$STATE_FILE"
  if grep -qE "^${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$STATE_FILE"
  fi
}

env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^${1}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

env_set() {
  local key=$1 value=$2 esc
  if [[ ! -f "$ENV_FILE" ]]; then
    printf '%s=%s\n' "$key" "$value" > "$ENV_FILE"
    return 0
  fi
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # escapa \, & y el | del reemplazo de sed
    esc="$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')"
    sed -i -E "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

container_id() { compose ps -aq "$1" 2>/dev/null | head -n1 || true; }

slot_health() {
  local cid; cid="$(container_id "api-$1")"
  if [[ -z "$cid" ]]; then echo missing; return 0; fi
  # running -> estado del healthcheck; parado -> exited/created (no el ultimo
  # healthcheck, que se queda congelado en 'unhealthy' al hacer `compose stop`)
  docker inspect --format '{{if .State.Running}}{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}{{else}}{{.State.Status}}{{end}}' \
    "$cid" 2>/dev/null || echo unknown
}

slot_image() {
  local cid; cid="$(container_id "api-$1")"
  if [[ -n "$cid" ]]; then
    local img; img="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
    if [[ -n "$img" ]]; then printf '%s' "$img"; return 0; fi
  fi
  env_get "API_IMAGE_${1^^}"
}

nginx_running() {
  local cid; cid="$(container_id nginx)"
  [[ -n "$cid" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" == "true" ]]
}

ensure_upstream_file() {
  if [[ ! -f "$UPSTREAM_FILE" ]]; then
    mkdir -p "$UPSTREAM_DIR"
    printf 'set $api_upstream http://api-blue:3000;\n' > "$UPSTREAM_FILE"
    warn "no existia ${UPSTREAM_FILE}; creado con el color por defecto (blue)"
  fi
}

# Asegura que API_IMAGE_<color> esta definida. Si no lo esta, manda lo que ya
# esta corriendo en ese slot; si aun no hay contenedor, la ultima imagen del
# registro (API_IMAGE). Asi un .env.production regenerado por Ansible/CI no
# "cambia" la imagen del color activo sin que nadie lo recuerde.
ensure_slot_key() {
  local color="$1" key="API_IMAGE_${1^^}" value=""
  value="$(env_get "$key")"
  if [[ -z "$value" ]]; then
    local cid; cid="$(container_id "api-${color}")"
    if [[ -n "$cid" ]]; then
      value="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$value" ]]; then
    value="$(env_get API_IMAGE)"
  fi
  [[ -n "$value" ]] || die "no se puede resolver la imagen de api-${color}: define ${key} (o API_IMAGE) en ${ENV_FILE}"
  env_set "$key" "$value"
}

http_code() {
  local url="$1" code=""
  if command -v curl > /dev/null 2>&1; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)" || code="000"
  elif command -v wget > /dev/null 2>&1; then
    if wget -q -T 10 -O /dev/null "$url" 2>/dev/null; then code="200"; else code="000"; fi
  else
    die "hace falta curl o wget para verificar"
  fi
  printf '%s' "$code"
}

public_base_url() {
  local port; port="$(env_get HTTP_PORT)"; printf 'http://127.0.0.1:%s' "${port:-80}"
}

# --- conmutacion ------------------------------------------------------------
# Escribe active.conf, lo valida dentro del contenedor y recarga nginx.
# Si algo falla, restaura el fichero anterior: el trafico no se mueve.
switch_traffic() {
  local target="$1"
  local backup="${UPSTREAM_FILE}.bak" tmp="${UPSTREAM_FILE}.tmp"

  [[ "$target" == "blue" || "$target" == "green" ]] || die "color invalido: ${target} (blue|green)"
  nginx_running || die "nginx no esta en marcha; no se puede conmutar (blue-green.sh deploy lo levanta solo)"

  cp -f "$UPSTREAM_FILE" "$backup"
  printf 'set $api_upstream http://api-%s:3000;\n' "$target" > "$tmp"
  mv -f "$tmp" "$UPSTREAM_FILE"       # rename atomico: nginx nunca ve un fichero a medias

  # El volumen solo monta el estado si el contenedor se creo con el compose
  # actual: comprueba que nginx ve de verdad el fichero nuevo.
  if ! compose exec -T nginx grep -q "api-${target}" /etc/nginx/upstream/active.conf 2>/dev/null; then
    cp -f "$backup" "$UPSTREAM_FILE"
    die "nginx no ve /etc/nginx/upstream/active.conf (falta el volumen ./nginx/upstream); trafico sin cambios"
  fi

  if ! compose exec -T nginx nginx -t; then
    cp -f "$backup" "$UPSTREAM_FILE"
    die "nginx -t ha rechazado la configuracion; trafico sin cambios en $(read_active)"
  fi

  compose exec -T nginx nginx -s reload
  # `reload` termina las conexiones en vuelo y solo despues usa el upstream nuevo.
  ok "trafico conmutado a ${target} (nginx recargado en caliente)"
}

# --- verificaciones ---------------------------------------------------------
verify_endpoint() {
  local url; url="$(public_base_url)/health"
  local i code="000"
  for i in $(seq 1 "$VERIFY_RETRIES"); do
    code="$(http_code "$url")"
    if [[ "$code" == "200" ]]; then
      ok "GET ${url} -> 200"
      return 0
    fi
    sleep 3
  done
  warn "GET ${url} no responde 200 (ultimo codigo: ${code})"
  return 1
}

verify_crud() {
  command -v curl > /dev/null 2>&1 || { warn "curl no esta instalado: CRUD no verificado"; return 0; }
  local base; base="$(public_base_url)"
  local created id code

  created="$(curl -fsS -X POST "${base}/todos" -H 'Content-Type: application/json' \
    -d '{"task":"Verificacion blue-green"}')" || { warn "POST /todos ha fallado"; return 1; }
  id="$(printf '%s' "$created" | sed -n 's/.*"_id":"\([^"]*\)".*/\1/p')"
  [[ -n "$id" ]] || { warn "no se pudo leer el _id devuelto"; return 1; }

  curl -fsS "${base}/todos/${id}" > /dev/null            || { warn "GET /todos/${id} ha fallado"; return 1; }
  curl -fsS -X PUT "${base}/todos/${id}" -H 'Content-Type: application/json' \
    -d '{"completed":true}' > /dev/null                  || { warn "PUT /todos/${id} ha fallado"; return 1; }
  curl -fsS -X DELETE "${base}/todos/${id}" > /dev/null  || { warn "DELETE /todos/${id} ha fallado"; return 1; }

  code="$(http_code "${base}/todos/${id}")"
  [[ "$code" == "404" ]] || { warn "GET /todos/${id} tras el borrado devuelve ${code} (esperado 404)"; return 1; }
  ok "CRUD completo verificado en ${base}"
}

# --- comandos ---------------------------------------------------------------
cmd_init() {
  ensure_upstream_file
  ok "estado de despliegue en ${UPSTREAM_FILE} (color activo: $(read_active))"
}

cmd_validate() {
  ensure_upstream_file
  ensure_slot_key blue
  ensure_slot_key green
  compose config --quiet || die "docker compose config ha fallado"
  ok "compose valido: ${COMPOSE_FILE} + ${ENV_FILE}"
}

cmd_deploy() {
  local image="" stop_previous=0 do_verify=1
  while (($#)); do
    case "$1" in
      --stop-previous) stop_previous=1 ;;
      --no-verify)     do_verify=0 ;;
      -*)              die "opcion desconocida: $1 (ver blue-green.sh help)" ;;
      *)               [[ -z "$image" ]] || die "solo se admite una imagen"
                       image="$1" ;;
    esac
    shift
  done
  [[ -n "$image" ]] || die "uso: blue-green.sh deploy <imagen> [--stop-previous] [--no-verify]"

  ensure_upstream_file
  local active target
  active="$(read_active)"
  target="$(other_color "$active")"

  info "color activo: ${active} | nuevo color: ${target} | imagen: ${image}"

  # El slot activo no se toca: su clave solo se completa si faltaba.
  env_set "API_IMAGE_${target^^}" "$image"
  ensure_slot_key "$active"
  compose config --quiet || die "docker compose config ha fallado (revisa ${ENV_FILE})"

  # nginx siempre presente antes de conmutar. `up -d` tambien recrea el
  # contenedor si ha cambiado el compose (p. ej. recien anadido el volumen
  # de nginx/upstream en un servidor que ya existia).
  info "asegurando el reverse proxy en marcha..."
  compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" nginx

  info "descargando la imagen y levantando api-${target} SIN tocar el trafico..."
  compose pull "api-${target}" || warn "pull fallado: se usara la imagen local de api-${target}"

  if ! compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" "api-${target}"; then
    compose ps
    compose logs --no-color --tail=50 "api-${target}" || true
    compose stop "api-${target}" > /dev/null 2>&1 || true
    die "api-${target} no llego a healthy: DESPLIEGUE ABORTADO, sigue sirviendo ${active}"
  fi

  if [[ "$(slot_health "$target")" != "healthy" ]]; then
    compose stop "api-${target}" > /dev/null 2>&1 || true
    die "api-${target} en estado $(slot_health "$target"): DESPLIEGUE ABORTADO, sigue sirviendo ${active}"
  fi

  # Segunda comprobacion: mismo camino de red que usara el trafico real.
  if ! compose exec -T nginx wget -qO- "http://api-${target}:3000/health" > /dev/null; then
    compose logs --no-color --tail=50 "api-${target}" || true
    compose stop "api-${target}" > /dev/null 2>&1 || true
    die "api-${target} responde a su healthcheck pero no desde la red de nginx: DESPLIEGUE ABORTADO"
  fi
  ok "api-${target} healthy y alcanzable desde nginx"

  # --- punto de no retorno: a partir de aqui el trafico cambia -------------
  switch_traffic "$target"

  if (( do_verify )); then
    if ! verify_endpoint || ! verify_crud; then
      warn "verificacion posterior a la conmutacion fallida: volviendo a ${active}"
      switch_traffic "$active" || true
      compose stop "api-${target}" > /dev/null 2>&1 || true
      die "rollback automatico aplicado: el trafico vuelve a ${active}"
    fi
  fi

  state_set PREVIOUS "$active"
  state_set DEPLOYED_IMAGE "$image"

  if (( stop_previous )); then
    info "retirando el color anterior (api-${active})"
    compose stop "api-${active}" > /dev/null
    ok "api-${active} parado; rollback manual: blue-green.sh deploy <imagen anterior>"
  else
    info "api-${active} queda en pie como blanco de rollback inmediato (blue-green.sh retire para pararlo)"
  fi

  cmd_status
  ok "despliegue terminado: ${image} sirviendo en ${target}"
}

cmd_switch() {
  local target="${1:-}"
  [[ "$target" == "blue" || "$target" == "green" ]] || die "uso: blue-green.sh switch <blue|green>"
  ensure_upstream_file

  local active; active="$(read_active)"
  [[ "$target" == "$active" ]] && die "el color ${target} ya esta sirviendo trafico"

  local health; health="$(slot_health "$target")"
  [[ "$health" == "healthy" ]] || die "api-${target} esta en '${health}', no se puede conmutar (usa deploy)"

  compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" nginx
  switch_traffic "$target"
  verify_endpoint || { switch_traffic "$active" || true; die "verificacion fallida: trafico devuelto a ${active}"; }
  state_set PREVIOUS "$active"
  cmd_status
}

cmd_rollback() {
  ensure_upstream_file
  local active previous health
  active="$(read_active)"
  previous="$(state_get PREVIOUS)"
  [[ -n "$previous" ]] || previous="$(other_color "$active")"
  [[ "$previous" != "$active" ]] || die "no hay un color anterior registrado (${STATE_FILE})"
  [[ "$previous" == "blue" || "$previous" == "green" ]] || die "estado invalido: PREVIOUS=${previous}"

  health="$(slot_health "$previous")"
  [[ "$health" == "healthy" ]] || die "api-${previous} esta en '${health}': rollback manual con blue-green.sh deploy <imagen>"

  info "revirtiendo el trafico: ${active} -> ${previous}"
  compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" nginx
  switch_traffic "$previous"
  verify_endpoint || { switch_traffic "$active" || true; die "verificacion fallida: el trafico se ha devuelto a ${active}"; }
  state_set PREVIOUS "$active"
  cmd_status
  ok "rollback terminado: sirve ${previous}"
}

cmd_retire() {
  ensure_upstream_file
  local active color
  active="$(read_active)"
  color="${1:-$(other_color "$active")}"
  [[ "$color" != "$active" ]] || die "no se puede parar el color activo (${active})"
  info "parando api-${color}"
  compose stop "api-${color}" > /dev/null
  ok "api-${color} parado (rollback requiere volver a desplegar su imagen)"
}

cmd_status() {
  local active previous code
  active="$(read_active)"
  previous="$(state_get PREVIOUS)"
  code="$(http_code "$(public_base_url)/health")"

  echo
  echo "  Color activo        : ${active}"
  echo "  Color anterior      : ${previous:-"(desconocido)"}"
  echo "  Imagen en produccion: $(state_get DEPLOYED_IMAGE || true)"
  echo "  Publico $(public_base_url)/health -> ${code}"
  echo
  printf '  %-7s %-10s %-45s %s\n' "SLOT" "ESTADO" "IMAGEN" "SERVIENDO"
  local color health image serving
  for color in blue green; do
    health="$(slot_health "$color")"
    image="$(slot_image "$color")"
    if [[ "$color" == "$active" ]]; then serving="si"; else serving="no"; fi
    printf '  %-7s %-10s %-45s %s\n' "$color" "$health" "${image:-"-"}" "$serving"
  done
  if nginx_running; then
    printf '  %-7s %-10s %s\n' "nginx" "running" "$(compose exec -T nginx nginx -v 2>&1 | head -n1)"
  else
    printf '  %-7s %-10s\n' "nginx" "parado"
  fi
  echo
  compose ps --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null || compose ps
}

cmd_verify() {
  local with_crud=0
  for arg in "$@"; do
    case "$arg" in
      --crud) with_crud=1 ;;
      *) die "uso: blue-green.sh verify [--crud]" ;;
    esac
  done
  verify_endpoint || die "el endpoint publico no responde"
  (( with_crud )) && verify_crud || true
}

cmd_help() {
  sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- main -------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    deploy)   cmd_deploy "$@" ;;
    switch)   cmd_switch "$@" ;;
    rollback) cmd_rollback "$@" ;;
    retire)   cmd_retire "$@" ;;
    status)   cmd_status "$@" ;;
    verify)   cmd_verify "$@" ;;
    validate) cmd_validate "$@" ;;
    init)     cmd_init "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "comando desconocido: ${cmd} (ver blue-green.sh help)" ;;
  esac
}

main "$@"
