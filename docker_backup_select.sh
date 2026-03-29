#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash docker_backup_select.sh [backup_dir]
# Example:
#   sudo bash docker_backup_select.sh /opt/docker-backups

BACKUP_ROOT="${1:-/opt/docker-backups}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
TMP_ROOT="$(mktemp -d /tmp/docker-backup.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

sanitize_name() {
  local raw="$1"
  local safe
  safe="$(echo "$raw" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-')"
  if [[ -z "$safe" ]]; then
    safe="app"
  fi
  printf '%s' "$safe"
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Please run as root (required to read Docker volume source paths)."
  exit 1
fi

require_cmd docker
require_cmd tar
require_cmd xargs

docker info >/dev/null 2>&1 || {
  echo "Docker daemon is not available."
  exit 1
}

docker compose version >/dev/null 2>&1 || {
  echo "docker compose is not available (Docker Compose v2 required)."
  exit 1
}

mkdir -p "$BACKUP_ROOT"

declare -a APP_KEYS=()
declare -a APP_LABELS=()
declare -a SELECTED_INDEXES=()
declare -A PROJECTS=()
declare -A STANDALONE_NAME_TO_CID=()
declare -A MOUNT_SET=()

discover_apps() {
  local cid proj name status count
  local -a all_cids

  mapfile -t all_cids < <(docker ps -aq)
  if (( ${#all_cids[@]} == 0 )); then
    echo "No containers found."
    exit 0
  fi

  for cid in "${all_cids[@]}"; do
    proj="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null || true)"
    if [[ -n "$proj" && "$proj" != "<no value>" ]]; then
      PROJECTS["$proj"]=1
    else
      name="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')"
      if [[ -n "$name" ]]; then
        STANDALONE_NAME_TO_CID["$name"]="$cid"
      fi
    fi
  done

  if (( ${#PROJECTS[@]} > 0 )); then
    while IFS= read -r proj; do
      [[ -z "$proj" ]] && continue
      count="$(docker ps -a -q --filter "label=com.docker.compose.project=$proj" | wc -l | tr -d ' ')"
      APP_KEYS+=("compose::$proj")
      APP_LABELS+=("Compose project: $proj ($count containers)")
    done < <(printf '%s\n' "${!PROJECTS[@]}" | sort)
  fi

  if (( ${#STANDALONE_NAME_TO_CID[@]} > 0 )); then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      cid="${STANDALONE_NAME_TO_CID[$name]}"
      status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")"
      APP_KEYS+=("container::$cid")
      APP_LABELS+=("Standalone container: $name [$status]")
    done < <(printf '%s\n' "${!STANDALONE_NAME_TO_CID[@]}" | sort)
  fi

  if (( ${#APP_KEYS[@]} == 0 )); then
    echo "No backup candidates found."
    exit 0
  fi
}

print_app_list() {
  local i
  echo "Discovered Docker apps:"
  for i in "${!APP_LABELS[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${APP_LABELS[$i]}"
  done
}

choose_apps() {
  local input token idx
  local -a tokens
  declare -A picked=()

  read -r -p "Select indexes to backup (example: 1,3,5 or all): " input
  input="$(echo "$input" | xargs)"
  if [[ -z "$input" ]]; then
    echo "Empty input, exit."
    exit 1
  fi

  if [[ "$input" == "all" || "$input" == "ALL" ]]; then
    for idx in "${!APP_KEYS[@]}"; do
      picked["$idx"]=1
    done
  else
    input="${input// /}"
    IFS=',' read -r -a tokens <<< "$input"
    for token in "${tokens[@]}"; do
      [[ -z "$token" ]] && continue
      if [[ ! "$token" =~ ^[0-9]+$ ]]; then
        echo "Invalid index: $token"
        exit 1
      fi
      idx=$((token - 1))
      if (( idx < 0 || idx >= ${#APP_KEYS[@]} )); then
        echo "Index out of range: $token"
        exit 1
      fi
      picked["$idx"]=1
    done
  fi

  mapfile -t SELECTED_INDEXES < <(printf '%s\n' "${!picked[@]}" | sort -n)
  if (( ${#SELECTED_INDEXES[@]} == 0 )); then
    echo "No app selected, exit."
    exit 1
  fi

  echo "Selected apps:"
  for idx in "${SELECTED_INDEXES[@]}"; do
    printf '  - %s\n' "${APP_LABELS[$idx]}"
  done
}

save_compose_files() {
  local project="$1"
  local stage_dir="$2"
  local first_cid working_dir config_files cfg cfg_path
  local -a cids cfgs

  mapfile -t cids < <(docker ps -a -q --filter "label=com.docker.compose.project=$project")
  (( ${#cids[@]} == 0 )) && return 0
  first_cid="${cids[0]}"

  working_dir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$first_cid" 2>/dev/null || true)"
  config_files="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$first_cid" 2>/dev/null || true)"

  mkdir -p "$stage_dir/compose_files"
  {
    echo "project=$project"
    echo "working_dir=$working_dir"
    echo "config_files=$config_files"
  } > "$stage_dir/compose_files/compose_meta.txt"

  if [[ -z "$config_files" || "$config_files" == "<no value>" ]]; then
    return 0
  fi

  IFS=',' read -r -a cfgs <<< "$config_files"
  for cfg in "${cfgs[@]}"; do
    [[ -z "$cfg" ]] && continue
    if [[ "$cfg" = /* ]]; then
      cfg_path="$cfg"
    else
      cfg_path="$working_dir/$cfg"
    fi
    if [[ -f "$cfg_path" ]]; then
      cp -a --parents "$cfg_path" "$stage_dir/compose_files/" 2>/dev/null || true
    fi
  done
}

collect_mounts_from_containers() {
  local cid mtype mname msource mdest key
  MOUNT_SET=()

  for cid in "$@"; do
    while IFS=$'\t' read -r mtype mname msource mdest; do
      [[ -z "$msource" ]] && continue
      key="${mtype}|${mname}|${msource}|${mdest}"
      MOUNT_SET["$key"]=1
    done < <(docker inspect --format '{{range .Mounts}}{{printf "%s\t%s\t%s\t%s\n" .Type .Name .Source .Destination}}{{end}}' "$cid")
  done
}

backup_mount_sources() {
  local stage_dir="$1"
  local key mtype mname msource mdest

  mkdir -p "$stage_dir/data"
  : > "$stage_dir/mounts.txt"

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    IFS='|' read -r mtype mname msource mdest <<< "$key"
    printf '%s\n' "$key" >> "$stage_dir/mounts.txt"

    if [[ ! -e "$msource" ]]; then
      log "Skip missing source: $msource"
      continue
    fi

    cp -a --parents "$msource" "$stage_dir/data/" 2>/dev/null || {
      log "Skip copy failure: $msource"
      continue
    }
  done < <(printf '%s\n' "${!MOUNT_SET[@]}" | sort)
}

down_compose_project() {
  local project="$1"
  local first_cid working_dir config_files cfg
  local -a cids cfgs compose_args

  mapfile -t cids < <(docker ps -a -q --filter "label=com.docker.compose.project=$project")
  (( ${#cids[@]} == 0 )) && return 0
  first_cid="${cids[0]}"

  working_dir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$first_cid" 2>/dev/null || true)"
  config_files="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$first_cid" 2>/dev/null || true)"

  compose_args=()
  if [[ -n "$config_files" && "$config_files" != "<no value>" ]]; then
    IFS=',' read -r -a cfgs <<< "$config_files"
    for cfg in "${cfgs[@]}"; do
      [[ -z "$cfg" ]] && continue
      if [[ "$cfg" = /* ]]; then
        compose_args+=("-f" "$cfg")
      else
        compose_args+=("-f" "$working_dir/$cfg")
      fi
    done
  fi

  if [[ -n "$working_dir" && "$working_dir" != "<no value>" && -d "$working_dir" ]]; then
    if (cd "$working_dir" && docker compose "${compose_args[@]}" down); then
      return 0
    fi
    log "compose down failed, fallback to force remove project containers: $project"
  fi

  log "Cannot resolve compose working directory, fallback to force remove containers: $project"
  docker rm -f "${cids[@]}" >/dev/null
}

stop_standalone_container() {
  local cid="$1"
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")"
  if [[ "$running" == "true" ]]; then
    docker stop "$cid" >/dev/null
  fi
}

pack_stage() {
  local stage_dir="$1"
  local output_file="$2"
  tar -czf "$output_file" -C "$stage_dir" .
}

process_selection() {
  local idx key kind value app_name safe_name stage_dir archive_path container_name
  local -a cids

  for idx in "${SELECTED_INDEXES[@]}"; do
    key="${APP_KEYS[$idx]}"
    kind="${key%%::*}"
    value="${key#*::}"
    app_name="$value"
    safe_name="$(sanitize_name "$app_name")"
    stage_dir="$TMP_ROOT/${safe_name}_${TIMESTAMP}"
    archive_path="$BACKUP_ROOT/${safe_name}_${TIMESTAMP}.tar.gz"

    mkdir -p "$stage_dir"
    printf 'selected_item=%s\n' "${APP_LABELS[$idx]}" > "$stage_dir/backup_meta.txt"

    if [[ "$kind" == "compose" ]]; then
      mapfile -t cids < <(docker ps -a -q --filter "label=com.docker.compose.project=$value")
      if (( ${#cids[@]} == 0 )); then
        log "Skip missing compose project containers: $value"
        continue
      fi

      docker inspect "${cids[@]}" > "$stage_dir/containers.inspect.json"
      save_compose_files "$value" "$stage_dir"
      collect_mounts_from_containers "${cids[@]}"

      log "Bring down compose project: $value"
      down_compose_project "$value"

      log "Backup mount data: $value"
      backup_mount_sources "$stage_dir"
    else
      if ! docker inspect "$value" >/dev/null 2>&1; then
        log "Skip missing container: $value"
        continue
      fi

      container_name="$(docker inspect -f '{{.Name}}' "$value" 2>/dev/null | sed 's#^/##')"
      if [[ -n "$container_name" ]]; then
        app_name="$container_name"
        safe_name="$(sanitize_name "$app_name")"
        stage_dir="$TMP_ROOT/${safe_name}_${TIMESTAMP}"
        archive_path="$BACKUP_ROOT/${safe_name}_${TIMESTAMP}.tar.gz"
        mkdir -p "$stage_dir"
        printf 'selected_item=%s\n' "${APP_LABELS[$idx]}" > "$stage_dir/backup_meta.txt"
      fi

      docker inspect "$value" > "$stage_dir/containers.inspect.json"
      collect_mounts_from_containers "$value"

      log "Stop standalone container: $value"
      stop_standalone_container "$value"

      log "Backup mount data: $value"
      backup_mount_sources "$stage_dir"
    fi

    pack_stage "$stage_dir" "$archive_path"
    log "Backup created: $archive_path"
  done
}

discover_apps
print_app_list
choose_apps

read -r -p "Selected apps will be brought down/stopped and backed up now. Continue? [y/N]: " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Canceled."
  exit 0
fi

process_selection
echo
echo "All done. Backup directory: $BACKUP_ROOT"
