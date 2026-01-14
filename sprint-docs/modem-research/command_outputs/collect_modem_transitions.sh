#!/bin/sh
# collect_modem_transitions_matrix.sh
#
# Usage:
#   MODEM=0 QMI_DEV=/dev/cdc-wdm0 \
#     sh collect_modem_transitions_matrix.sh \
#       /tmp/transitions enabled on
#
# Args:
#   $1 = RUN_DIR (root output dir)
#   $2 = INITIAL_MODEM_STATE: registered|disabled|connected
#   $3 = INITIAL_SIM_STATE:   on|off
#
# You should manually verify the modem really starts in this state.

set -u

RUN_DIR="${1:-/tmp/modem_transitions}"
INITIAL_MODEM_STATE="${2:-registered}"  # registered|disabled|connected
INITIAL_SIM_STATE="${3:-on}"         # on|off

MODEM="${MODEM:-0}"
QMI_DEV="${QMI_DEV:-/dev/cdc-wdm0}"

echo "RUN_DIR='${RUN_DIR}', INITIAL_MODEM_STATE='${INITIAL_MODEM_STATE}', INITIAL_SIM_STATE='${INITIAL_SIM_STATE}', MODEM='${MODEM}', QMI_DEV='${QMI_DEV}'" >&2

# Outputs go under:
#   ${RUN_DIR}/${INITIAL_MODEM_STATE}_modem_${INITIAL_SIM_STATE}_sim/mmcli/<name>.txt
#   ${RUN_DIR}/${INITIAL_MODEM_STATE}_modem_${INITIAL_SIM_STATE}_sim/qmicli/<name>.txt
INITIAL_STATE_DIR="${RUN_DIR}/${INITIAL_MODEM_STATE}_modem_${INITIAL_SIM_STATE}_sim"
MMCLI_DIR="${INITIAL_STATE_DIR}/mmcli"
QMI_DIR="${INITIAL_STATE_DIR}/qmicli"

mkdir -p "${MMCLI_DIR}" "${QMI_DIR}"

ensure_modem_state() {
  case "$1" in
    registered)
      mmcli -m "${MODEM}" -e >/dev/null 2>&1 || true
      sleep 1
      ;;
    connected)
      if [ -z "${CONNECTION_STRING:-}" ]; then
        echo "CONNECTION_STRING is not set; cannot ensure 'connected' state." >&2
        return 1
      fi
      mmcli -m "${MODEM}" --simple-connect="${CONNECTION_STRING}"
      sleep 1
      ;;
    disabled)
      mmcli -m "${MODEM}" -d >/dev/null 2>&1 || true
      ;;
    *)
      echo "Unknown modem state '$1' (expected registered|disabled|connected)" >&2
      ;;
  esac
}

ensure_sim_state() {
  case "$1" in
    on)
      qmicli -p -d "${QMI_DEV}" --uim-sim-power-on=1 >/dev/null 2>&1 || true
      ;;
    off)
      qmicli -p -d "${QMI_DEV}" --uim-sim-power-off=1 >/dev/null 2>&1 || true
      ;;
    *)
      echo "Unknown SIM state '$1' (expected on|off)" >&2
      ;;
  esac
}

# Helper to run a single experiment:
#   name: logical name (e.g. mm-enable, sim-power-off)
#   kind: "modem" or "sim" (which aspect this experiment changes)
#   forward: shell code for the transition command (no redirection)
run_experiment() {
  name="$1"
  kind="$2"
  forward_cmd="$3"

  echo "=== Experiment '${name}' (initial state ${INITIAL_MODEM_STATE}/${INITIAL_SIM_STATE}) ===" >&2

  # 1. Force the relevant initial state (modem *or* SIM, not both)
  case "${kind}" in
    modem)
      ensure_modem_state "${INITIAL_MODEM_STATE}"
      ;;
    sim)
      ensure_sim_state "${INITIAL_SIM_STATE}"
      ;;
    *)
      echo "Unknown experiment kind '${kind}' (expected modem|sim)" >&2
      ;;
  esac

  # 2. Run transition and capture output
  #    Choose output directory based on kind and write to <name>.txt
  case "${kind}" in
    modem)
      out_file="${MMCLI_DIR}/${name}.txt"
      ;;
    sim)
      out_file="${QMI_DIR}/${name}.txt"
      ;;
    *)
      out_file="${INITIAL_STATE_DIR}/${name}.txt"
      ;;
  esac

  # shellcheck disable=SC2086
  sh -c "${forward_cmd} > '${out_file}' 2>&1" || true

  # 3. Restore initial state for the same aspect (modem or SIM)
  case "${kind}" in
    modem)
      ensure_modem_state "${INITIAL_MODEM_STATE}"
      ;;
    sim)
      ensure_sim_state "${INITIAL_SIM_STATE}"
      ;;
  esac
}

###############################################################################
# Define experiments
#
# You can comment out any you don’t care about.
###############################################################################

# Modem enable (forward: -e, reverse: ensure initial state again)
run_experiment \
  "mm-enable" \
  "modem" \
  "mmcli -m '${MODEM}' -e"

# Modem disable
run_experiment \
  "mm-disable" \
  "modem" \
  "mmcli -m '${MODEM}' -d"

# SIM power off
run_experiment \
  "sim-power-off" \
  "sim" \
  "qmicli -p -d '${QMI_DEV}' --uim-sim-power-off=1"

# SIM power on
run_experiment \
  "sim-power-on" \
  "sim" \
  "qmicli -p -d '${QMI_DEV}' --uim-sim-power-on=1"

echo "All experiments done; each should have returned to initial state (best effort)." >&2
