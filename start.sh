#!/usr/bin/env bash
# ==============================================================================
#  🏔️ Everest Minecraft Server Controller
# ==============================================================================
#  Features:
#    - Automatic tmux background execution & session management
#    - Complete CLI controls: start, stop, restart, console, status, logs, cmd
#    - Android/Termux wake-lock integration (prevents CPU sleep)
#    - PaperMC auto-JAR detection & Aikar's optimized G1GC flags
#    - Crash-loop protection & graceful shutdown handler
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
SESSION_NAME="${EVEREST_SESSION:-everest}"
MIN_RAM="${MIN_RAM:-2048M}"
MAX_RAM="${MAX_RAM:-4096M}"
SERVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOG_FILE="${SERVER_DIR}/logs/latest.log"

# Aikar's Optimized Garbage Collection Flags
JAVA_FLAGS=(
  "-Xms${MIN_RAM}"
  "-Xmx${MAX_RAM}"
  "-XX:+AlwaysPreTouch"
  "-XX:+DisableExplicitGC"
  "-XX:+PerfDisableSharedMem"
  "-XX:+UnlockExperimentalVMOptions"
  "-XX:+UseG1GC"
  "-XX:G1HeapRegionSize=8M"
  "-XX:G1HeapWastePercent=5"
  "-XX:G1MaxNewSizePercent=40"
  "-XX:G1MixedGCCountTarget=4"
  "-XX:G1MixedGCLiveThresholdPercent=90"
  "-XX:G1NewSizePercent=30"
  "-XX:G1RSetUpdatingPauseTimePercent=5"
  "-XX:G1ReservePercent=20"
  "-XX:InitiatingHeapOccupancyPercent=15"
  "-XX:MaxGCPauseMillis=200"
  "-XX:MaxTenuringThreshold=1"
  "-XX:SurvivorRatio=32"
  "-Dusing.aikars.flags=https://mcflags.emc.gs"
  "-Daikars.new.flags=true"
)

# ------------------------------------------------------------------------------
# Colors & Logging
# ------------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[0;34m'
  C_CYAN=$'\033[0;36m'
  C_GRAY=$'\033[0;90m'
else
  C_RESET=''
  C_BOLD=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_CYAN=''
  C_GRAY=''
fi

log_info()    { printf '%s[%s]%s %s[INFO]%s  %s\n' "$C_GRAY" "$(date '+%H:%M:%S')" "$C_RESET" "$C_BLUE" "$C_RESET" "$*"; }
log_success() { printf '%s[%s]%s %s[OK]%s    %s\n' "$C_GRAY" "$(date '+%H:%M:%S')" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"; }
log_warn()    { printf '%s[%s]%s %s[WARN]%s  %s\n' "$C_GRAY" "$(date '+%H:%M:%S')" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*"; }
log_error()   { printf '%s[%s]%s %s[ERROR]%s %s\n' "$C_GRAY" "$(date '+%H:%M:%S')" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2; }

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

# Check if the tmux session is currently active
is_running() {
  tmux has-session -t "$SESSION_NAME" 2>/dev/null
}

# Find the latest Paper server JAR
find_server_jar() {
  local jar
  # Prefer paper-*.jar sorted by version descending
  jar=$(ls -1t "${SERVER_DIR}"/paper-*.jar 2>/dev/null | head -n 1 || true)
  if [[ -z "$jar" ]]; then
    # Fallback to server.jar or any *.jar excluding plugins/libraries
    jar=$(ls -1t "${SERVER_DIR}"/*.jar 2>/dev/null | head -n 1 || true)
  fi

  if [[ -z "$jar" || ! -f "$jar" ]]; then
    log_error "No server JAR found in ${SERVER_DIR}!"
    log_warn "Please run ./update.sh first to download the latest PaperMC build."
    exit 1
  fi
  echo "$jar"
}

# Acquire Termux wake-lock if available to prevent Android sleep
acquire_wake_lock() {
  if command -v termux-wake-lock &>/dev/null; then
    termux-wake-lock 2>/dev/null || true
    log_info "Acquired Termux wake-lock (CPU sleep disabled)."
  fi
}

# ------------------------------------------------------------------------------
# Internal Server Runner (Runs inside tmux or foreground)
# ------------------------------------------------------------------------------
run_server_loop() {
  cd "$SERVER_DIR"
  local jar
  jar="$(find_server_jar)"
  local jar_name
  jar_name="$(basename "$jar")"

  echo -e "${C_CYAN}${C_BOLD}======================================================${C_RESET}"
  echo -e "${C_CYAN}🏔️  Everest Minecraft Server Launching...${C_RESET}"
  echo -e "${C_GRAY}   JAR : ${jar_name}${C_RESET}"
  echo -e "${C_GRAY}   RAM : ${MIN_RAM} ~ ${MAX_RAM}${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}======================================================${C_RESET}"

  local crash_count=0
  local last_crash=0

  while true; do
    local start_time
    start_time=$(date +%s)

    java "${JAVA_FLAGS[@]}" -jar "$jar" --nogui

    local exit_code=$?
    local end_time
    end_time=$(date +%s)
    local run_duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 ]]; then
      echo -e "\n${C_GREEN}Server shut down cleanly (exit code 0).${C_RESET}"
      break
    fi

    # Crash handling & loop protection
    echo -e "\n${C_RED}[WARN] Server crashed or stopped with code ${exit_code}!${C_RESET}"

    # If it crashed in less than 30 seconds, increment fast-crash counter
    if [[ $run_duration -lt 30 ]]; then
      ((crash_count++))
      if [[ $crash_count -ge 3 ]]; then
        echo -e "${C_RED}${C_BOLD}[FATAL] Server crashed 3 times consecutively within 30s. Aborting auto-restart!${C_RESET}"
        echo -e "${C_YELLOW}Check logs at: ${LOG_FILE}${C_RESET}"
        read -r -p "Press Enter to exit..." || true
        break
      fi
    else
      crash_count=0
    fi

    echo -e "${C_YELLOW}Restarting server in 5 seconds... (Press Ctrl+C to cancel)${C_RESET}"
    sleep 5
  done
}

# ------------------------------------------------------------------------------
# Controller Actions
# ------------------------------------------------------------------------------

cmd_start() {
  if is_running; then
    log_warn "Server is ALREADY running in tmux session '${SESSION_NAME}'!"
    cmd_status
    echo -e "\n${C_BOLD}To view console:${C_RESET} ${C_CYAN}./start.sh console${C_RESET} or ${C_CYAN}tmux a -t ${SESSION_NAME}${C_RESET}"
    return 0
  fi

  acquire_wake_lock
  local jar
  jar="$(find_server_jar)"
  log_info "Starting Everest server in background (tmux session: '${C_CYAN}${SESSION_NAME}${C_RESET}')..."
  log_info "Using JAR: $(basename "$jar") [RAM: ${MIN_RAM} - ${MAX_RAM}]"

  # Launch inside detached tmux session
  tmux new-session -d -s "$SESSION_NAME" -c "$SERVER_DIR" \
    "$0" __internal_run

  sleep 1

  if is_running; then
    log_success "Server successfully started in background!"
    echo ""
    echo -e "  ${C_BOLD}Useful Commands:${C_RESET}"
    echo -e "    ${C_GREEN}./start.sh console${C_RESET}   - Attach to server console"
    echo -e "    ${C_GREEN}./start.sh logs${C_RESET}      - Stream live log output"
    echo -e "    ${C_GREEN}./start.sh status${C_RESET}    - Check server process status"
    echo -e "    ${C_GREEN}./start.sh stop${C_RESET}      - Gracefully stop the server"
    echo -e "    ${C_GRAY}(Tip: While in console, press ${C_YELLOW}Ctrl+B${C_GRAY} then ${C_YELLOW}D${C_GRAY} to detach)${C_RESET}"
    echo ""
  else
    log_error "Failed to start tmux session!"
    exit 1
  fi
}

cmd_console() {
  if ! is_running; then
    log_error "Server is NOT running. Start it with: ./start.sh"
    exit 1
  fi
  echo -e "${C_GRAY}Attaching to console. Press ${C_YELLOW}Ctrl+B${C_GRAY} then ${C_YELLOW}D${C_GRAY} to detach safely without stopping server.${C_RESET}"
  sleep 0.5
  tmux attach-session -t "$SESSION_NAME"
}

cmd_stop() {
  if ! is_running; then
    log_warn "Server is not currently running."
    return 0
  fi

  tmux send-keys -t "$SESSION_NAME" -l "stop"
  tmux send-keys -t "$SESSION_NAME" Enter

  local timeout=30
  local count=0
  printf "%sWaiting for server to save chunks and shutdown...%s " "$C_GRAY" "$C_RESET"

  while is_running && [[ $count -lt $timeout ]]; do
    sleep 1
    printf "."
    ((count++))
  done
  echo ""

  if is_running; then
    log_warn "Server did not exit within ${timeout}s. Terminating tmux session..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
  fi

  log_success "Server stopped."
}

cmd_restart() {
  log_info "Restarting Everest server..."
  if is_running; then
    cmd_stop
    sleep 2
  fi
  cmd_start
}

cmd_status() {
  echo -e "${C_BOLD}--- Everest Server Status ---${C_RESET}"
  if is_running; then
    echo -e "  Status       : ${C_GREEN}● RUNNING${C_RESET}"
    echo -e "  tmux Session : ${C_CYAN}${SESSION_NAME}${C_RESET}"

    # Search for Java PID
    local pid
    pid=$(pgrep -f "paper.*\.jar" | head -n 1 || true)
    if [[ -n "$pid" ]]; then
      local mem_info cpu_info
      mem_info=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}' || echo "N/A")
      echo -e "  Java PID     : ${pid}"
      echo -e "  Memory (RSS) : ${mem_info}"
    fi

    # Check port 25565
    if command -v ss &>/dev/null; then
      if ss -tulpn 2>/dev/null | grep -q ":25565"; then
        echo -e "  Port 25565   : ${C_GREEN}Listening${C_RESET}"
      fi
    fi
  else
    echo -e "  Status       : ${C_RED}○ STOPPED${C_RESET}"
  fi
  echo -e "-----------------------------"
}

cmd_logs() {
  if [[ -f "$LOG_FILE" ]]; then
    echo -e "${C_GRAY}Streaming ${LOG_FILE} (Ctrl+C to exit)...${C_RESET}"
    tail -f -n 50 "$LOG_FILE"
  else
    log_warn "Log file not found at ${LOG_FILE}"
  fi
}

cmd_send() {
  if ! is_running; then
    log_error "Server is not running!"
    exit 1
  fi
  local command="$*"
  if [[ -z "$command" ]]; then
    log_error "No command provided to send."
    exit 1
  fi
  log_info "Sending command to server: '${command}'"
  tmux send-keys -t "$SESSION_NAME" -l "$command"
  tmux send-keys -t "$SESSION_NAME" Enter
  log_success "Command dispatched."
}

# ------------------------------------------------------------------------------
# Entry Point
# ------------------------------------------------------------------------------

ACTION="${1:-start}"

case "$ACTION" in
  __internal_run)
    run_server_loop
    ;;
  start)
    cmd_start
    ;;
  console|attach|c|a)
    cmd_console
    ;;
  stop)
    cmd_stop
    ;;
  restart|r)
    cmd_restart
    ;;
  status|s)
    cmd_status
    ;;
  logs|log|l)
    cmd_logs
    ;;
  cmd|send|exec)
    shift
    cmd_send "$@"
    ;;
  fg|run|foreground)
    run_server_loop
    ;;
  help|-h|--help)
    echo -e "${C_BOLD}Usage:${C_RESET} $0 [command]"
    echo ""
    echo -e "  ${C_CYAN}start${C_RESET} (default)     Start server in background via tmux"
    echo -e "  ${C_CYAN}console${C_RESET}, ${C_CYAN}attach${C_RESET}     Attach to server interactive console"
    echo -e "  ${C_CYAN}stop${C_RESET}                Gracefully save and stop the server"
    echo -e "  ${C_CYAN}restart${C_RESET}             Restart the server"
    echo -e "  ${C_CYAN}status${C_RESET}              Show server running state and resource usage"
    echo -e "  ${C_CYAN}logs${C_RESET}                Follow server log in real-time"
    echo -e "  ${C_CYAN}cmd <command>${C_RESET}       Send in-game command (e.g. ./start.sh cmd say hi)"
    echo -e "  ${C_CYAN}fg${C_RESET}                  Run directly in foreground"
    echo ""
    ;;
  *)
    log_error "Unknown action: $ACTION"
    echo "Run '$0 help' for available commands."
    exit 1
    ;;
esac
