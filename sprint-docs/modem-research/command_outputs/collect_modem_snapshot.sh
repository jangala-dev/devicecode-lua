#!/bin/sh
# collect_modem_snapshot.sh
# Usage: ./collect_modem_snapshot.sh /tmp/idle_run
# Env overrides (optional): MODEM, SIM, QMI_DEV

set -u

RUN_DIR="${1:-/tmp/modem_run}"
MODEM="${MODEM:-0}"
SIM="${SIM:-0}"
QMI_DEV="${QMI_DEV:-/dev/cdc-wdm0}"

MMCLI_DIR="${RUN_DIR}/mmcli"
QMI_DIR="${RUN_DIR}/qmicli"

mkdir -p "${MMCLI_DIR}" "${QMI_DIR}"

echo "Snapshot in RUN_DIR='${RUN_DIR}', MODEM='${MODEM}', SIM='${SIM}', QMI_DEV='${QMI_DEV}'" >&2

###############################################################################
# mmcli read-only snapshots
###############################################################################

# mmcli -J -m <MODEM>
mmcli -J -m "${MODEM}" \
  > "${MMCLI_DIR}/modem.json" 2>&1 || true

# mmcli -J -i <SIM>
mmcli -J -i "${SIM}" \
  > "${MMCLI_DIR}/sim.json" 2>&1 || true

# mmcli -J -m <MODEM> --signal-get
mmcli -J -m "${MODEM}" --signal-get \
  > "${MMCLI_DIR}/signal.json" 2>&1 || true

# mmcli -J -m <MODEM> --location-status
mmcli -J -m "${MODEM}" --location-status \
  > "${MMCLI_DIR}/location-status.json" 2>&1 || true

###############################################################################
# qmicli read-only snapshots
###############################################################################

# qmicli --uim-get-card-status
qmicli -p -d "${QMI_DEV}" --uim-get-card-status \
  > "${QMI_DIR}/uim-get-card-status.txt" 2>&1 || true

# qmicli --uim-read-transparent=...6F3E (GID1)
qmicli -p -d "${QMI_DEV}" --uim-read-transparent=0x3F00,0x7FFF,0x6F3E \
  > "${QMI_DIR}/uim-read-transparent-gid1.txt" 2>&1 || true

# qmicli --nas-get-rf-band-info
qmicli -p -d "${QMI_DEV}" --nas-get-rf-band-info \
  > "${QMI_DIR}/nas-get-rf-band-info.txt" 2>&1 || true

# qmicli --nas-get-home-network
qmicli -p -d "${QMI_DEV}" --nas-get-home-network \
  > "${QMI_DIR}/nas-get-home-network.txt" 2>&1 || true

# qmicli --nas-get-serving-system
qmicli -p -d "${QMI_DEV}" --nas-get-serving-system \
  > "${QMI_DIR}/nas-get-serving-system.txt" 2>&1 || true

# qmicli --nas-get-signal-info
qmicli -p -d "${QMI_DEV}" --nas-get-signal-info \
  > "${QMI_DIR}/nas-get-signal-info.txt" 2>&1 || true

echo "Snapshot done under '${RUN_DIR}'." >&2
