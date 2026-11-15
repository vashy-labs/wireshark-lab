#!/usr/bin/env bash
# =============================================================
#  run-batch.sh - run several lab scenarios one after another
#  Usage: cd ~/wireshark-lab && sudo bash run-batch.sh s05 s06 s08
#  A scenario that fails does not stop the others. Everything printed
#  is also saved in captures/batch-log.txt.
# =============================================================
cd "$(dirname "$(readlink -f "$0")")"
LOG=captures/batch-log.txt
mkdir -p captures
: > "$LOG"
ok=() ; failed=()

for name in "$@"; do
  script="scenarios/$name.sh"
  {
    echo
    echo "################ $name ################"
  } | tee -a "$LOG"
  if [[ ! -f "$script" ]]; then
    echo "!! $script not found" | tee -a "$LOG"
    failed+=("$name")
    continue
  fi
  sed -i 's/\r$//' "$script" lib/common.sh
  chmod +x "$script"
  if bash "$script" 2>&1 | tee -a "$LOG"; [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    ok+=("$name")
  else
    echo "!! $name stopped with an error" | tee -a "$LOG"
    failed+=("$name")
  fi
done

{
  echo
  echo "################ summary ################"
  echo "finished: ${ok[*]:-none}"
  echo "failed:   ${failed[*]:-none}"
} | tee -a "$LOG"
chown "${SUDO_USER:-lab}" "$LOG" captures 2>/dev/null || true
