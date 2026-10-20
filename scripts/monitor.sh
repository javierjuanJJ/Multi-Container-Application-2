#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Watchdog liviano del despliegue blue-green (solo Docker + curl, sin extras).
#
#   ./scripts/monitor.sh                 estado actual (una tabla)
#   ./scripts/monitor.sh --watch 5       refresca cada 5 s (5 por defecto)
#   ./scripts/monitor.sh --watch 5 --auto-rollback
#
# Con --auto-rollback, si el color activo o el endpoint publico llevan
# FALLAS consecutivas (3 por defecto) se ejecuta `blue-green.sh rollback`,
# que devuelve el trafico al color anterior (que se queda parado en pie
# justo para esto). Desactivado por defecto: activarlo es una decision
# operativa, no una tecnica.
#
# Para el monitoreo "de verdad" (historico, dashboards, alertas por correo)
# hay un stack de Prometheus + cadvisor + blackbox-exporter en
# docker-compose.monitoring.yml.
# ---------------------------------------------------------------------------
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-.env.production}"
INTERVAL="${INTERVAL:-5}"
FALLAS_MAX="${FALLAS_MAX:-3}"
AUTO_ROLLBACK="${AUTO_ROLLBACK:-0}"

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

UPSTREAM_FILE="${DEPLOY_DIR}/nginx/upstream/active.conf"
BLUE_GREEN="${script_dir}/blue-green.sh"
[[ -x "$BLUE_GREEN" ]] || BLUE_GREEN="${DEPLOY_DIR}/blue-green.sh"

cd "$DEPLOY_DIR"
compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

active_color() {
  local color=""
  if [[ -f "$UPSTREAM_FILE" ]]; then
    color="$(grep -Eo 'api-(blue|green)' "$UPSTREAM_FILE" | head -n1 | cut -d- -f2 || true)"
  fi
  printf '%s' "${color:-blue}"
}

slot_health() {
  local cid
  cid="$(compose ps -aq "api-$1" 2>/dev/null | head -n1 || true)"
  [[ -n "$cid" ]] || { echo missing; return 0; }
  docker inspect --format '{{if .State.Running}}{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}{{else}}{{.State.Status}}{{end}}' \
    "$cid" 2>/dev/null || echo unknown
}

public_code() {
  local port code
  port="$(grep -E '^HTTP_PORT=' "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  if command -v curl > /dev/null 2>&1; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
      "http://127.0.0.1:${port:-80}/health" 2>/dev/null)" || code="000"
  else
    code="(sin curl)"
  fi
  printf '%s' "$code"
}

table() {
  local active blue green code
  active="$(active_color)"
  blue="$(slot_health blue)"
  green="$(slot_health green)"
  code="$(public_code)"

  echo
  printf '  %-7s %-10s %s\n' "SLOT" "ESTADO" "SERVIENDO"
  printf '  %-7s %-10s %s\n' "blue"  "$blue"  "$( [[ "$active" == blue  ]] && echo si || echo no )"
  printf '  %-7s %-10s %s\n' "green" "$green" "$( [[ "$active" == green ]] && echo si || echo no )"
  printf '  %-7s %-10s %s\n\n' "public" "$code" "http://127.0.0.1:<HTTP_PORT>/health"
}

watch_loop() {
  local active health code fallas=0
  info "watchdog blue-green cada ${INTERVAL}s (ctrl+c para parar)"
  while true; do
    active="$(active_color)"
    health="$(slot_health "$active")"
    code="$(public_code)"

    if [[ "$health" == "healthy" && "$code" == "200" ]]; then
      fallas=0
      printf '%s  activo=%-5s azul=%-8s verde=%-8s http=%s\n' \
        "$(date '+%H:%M:%S')" "$active" "$(slot_health blue)" "$(slot_health green)" "$code"
    else
      fallas=$((fallas + 1))
      printf '%s  activo=%-5s estado=%-8s http=%s  FALLA %s/%s\n' \
        "$(date '+%H:%M:%S')" "$active" "$health" "$code" "$fallas" "$FALLAS_MAX" >&2

      if (( fallas >= FALLAS_MAX )); then
        if (( AUTO_ROLLBACK )); then
          warn "color activo (${active}) caido en ${fallas} comprobaciones seguidas: rollback automatico"
          if "$BLUE_GREEN" rollback; then
            fallas=0
            warn "rollback aplicado; el trafico vuelve al color anterior"
          else
            warn "el rollback no ha sido posible: revision manual urgente"
            exit 1
          fi
        else
          warn "color activo (${active}) caido. Prueba: ${BLUE_GREEN} rollback"
        fi
      fi
    fi
    sleep "$INTERVAL"
  done
}

info() { printf '==> %s\n' "$*"; }
warn() { printf 'AVISO %s\n' "$*" >&2; }

main() {
  local watch=0
  while (($#)); do
    case "$1" in
      --watch)
        watch=1
        if [[ "${2:-}" =~ ^[0-9]+$ ]]; then INTERVAL="$2"; shift; fi
        ;;
      --auto-rollback) AUTO_ROLLBACK=1 ;;
      -h|--help)
        sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) printf 'comando desconocido: %s (ver --help)\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done
  if (( watch )); then watch_loop; else table; fi
}

main "$@"
