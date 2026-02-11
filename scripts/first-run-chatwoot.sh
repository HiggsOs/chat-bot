#!/usr/bin/env bash
set -Eeuo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yaml}"
APP_URL="${APP_URL:-http://127.0.0.1:3000}"
MIGRATION_RETRIES="${MIGRATION_RETRIES:-5}"
WAIT_RETRIES="${WAIT_RETRIES:-60}"
WAIT_SECONDS="${WAIT_SECONDS:-2}"
MIGRATION_SERVICE="${MIGRATION_SERVICE:-migrations}"

DC=(docker compose -f "$COMPOSE_FILE")

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' no esta instalado." >&2
    exit 1
  fi
}

service_exists() {
  "${DC[@]}" config --services | grep -Fxq "$1"
}

wait_for_postgres() {
  log "Esperando postgres..."
  local i
  for i in $(seq 1 "$WAIT_RETRIES"); do
    if "${DC[@]}" exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
      log "Postgres listo."
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  log "Postgres no estuvo listo a tiempo."
  return 1
}

run_migration_command() {
  if service_exists "$MIGRATION_SERVICE"; then
    "${DC[@]}" run --rm "$MIGRATION_SERVICE"
    return $?
  fi

  if service_exists rails; then
    log "Servicio '$MIGRATION_SERVICE' no existe; usando 'rails' para migrar."
    "${DC[@]}" run --rm rails bundle exec rails db:chatwoot_prepare
    return $?
  fi

  log "No existe servicio '$MIGRATION_SERVICE' ni 'rails' en $COMPOSE_FILE"
  return 1
}

run_migrations() {
  local attempt
  for attempt in $(seq 1 "$MIGRATION_RETRIES"); do
    log "Ejecutando migraciones (intento $attempt/$MIGRATION_RETRIES)..."
    if run_migration_command; then
      log "Migraciones completadas."
      return 0
    fi
    log "Migraciones fallaron."
    sleep 3
  done
  return 1
}

wait_for_web() {
  log "Esperando respuesta HTTP en $APP_URL ..."
  local i code
  for i in $(seq 1 "$WAIT_RETRIES"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$APP_URL" || true)"
    if [[ "$code" == "200" || "$code" == "302" ]]; then
      log "Chatwoot responde con HTTP $code."
      return 0
    fi
    sleep "$WAIT_SECONDS"
  done
  log "Chatwoot no respondio a tiempo."
  return 1
}

main() {
  require_cmd docker
  require_cmd curl

  log "Validando compose: $COMPOSE_FILE"
  "${DC[@]}" config >/dev/null

  log "Levantando infraestructura base (postgres, redis)..."
  "${DC[@]}" up -d postgres redis

  wait_for_postgres
  run_migrations

  log "Levantando servicios de app (rails, sidekiq)..."
  "${DC[@]}" up -d rails sidekiq

  wait_for_web

  log "Estado final de contenedores:"
  "${DC[@]}" ps

  log "Listo. Abre: $APP_URL"
}

main "$@"
