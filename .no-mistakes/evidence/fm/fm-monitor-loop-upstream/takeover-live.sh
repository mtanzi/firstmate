#!/usr/bin/env bash
# Live take-over scenario: real herdr fm-lab session, real watcher in its real
# herdr event wait, real fm-watch-arm.sh --take-over. Arg1: root to run arm/watcher from.
set -u
RUNROOT=$1; LABEL=$2
WT=/Users/mtanzi/.no-mistakes/worktrees/233970cc3bb4/01M5T0J59DD9MRHXWK8C5HEJ01
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
S=$("$WT/bin/fm-herdr-lab.sh" name "$LABEL")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() {
  [ -n "${TPID:-}" ] && kill "$TPID" 2>/dev/null
  [ -n "${APID:-}" ] && kill "$APID" 2>/dev/null
  wp=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null | head -1); [ -n "$wp" ] && kill "$wp" 2>/dev/null
  sleep 1; pkill -f "$LAB" 2>/dev/null
  "$WT/bin/fm-herdr-lab.sh" teardown "$S" >/dev/null 2>&1 && echo "teardown $S ok"
  rm -rf "$LAB"
}
trap cleanup EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; LAB=$(cd "$LAB" && pwd -P)
"$WT/bin/fm-herdr-lab.sh" prepare "$S" || { echo "prepare failed"; exit 1; }
PANE=$(HERDR_SESSION=$S bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr
  raw=$(fm_backend_herdr_container_ensure /tmp) || exit 1
  ids=$(fm_backend_herdr_create_task "${raw%%$(printf "\t")*}" fm-takeover /tmp "${raw#*$(printf "\t")}") || exit 1
  set -- $ids; echo "$2"' _ "$WT")
[ -n "$PANE" ] || { echo "no pane"; exit 1; }
"$WT/bin/fm-herdr-lab.sh" run "$S" pane report-agent "$PANE" --source fm-takeover --agent claude --state working >/dev/null
printf 'window=%s:%s\nbackend=herdr\nkind=ship\nproject=demo\n' "$S" "$PANE" > "$LAB/state/demo.meta"
echo "session=$S pane=$PANE lab=$LAB root=$RUNROOT"
export FM_HOME=$LAB HERDR_SESSION=$S
cd "$RUNROOT"
# Seed the primary's normal precondition: a prior downtime episode main has
# drained and acknowledged (marker acked:*), as after any earlier recovery.
bin/fm-watch-arm.sh > "$LAB/arm0.out" 2>&1 & A0=$!
for i in $(seq 1 100); do [ -s "$LAB/state/.watch.lock/pid" ] && break; sleep 0.1; done
sleep 2; bin/fm-watch-arm.sh --stop > "$LAB/stop0.out" 2>&1; wait "$A0" 2>/dev/null
bin/fm-watch-arm.sh > "$LAB/arm1.out" 2>&1
echo "seed: arm0 $(tail -1 "$LAB/arm0.out" 2>/dev/null) | stop: $(cat "$LAB/stop0.out") | rearm: $(tr '\n' ' ' < "$LAB/arm1.out")"
DRAIN=$(bin/fm-wake-drain.sh 2>&1)
ACK=$(printf '%s\n' "$DRAIN" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
[ -n "$ACK" ] && bin/fm-wake-drain.sh $ACK >/dev/null 2>&1
echo "seed: main acked with [$ACK]; marker before take-over: $(cat "$LAB/state/.watcher-down" 2>/dev/null)"
: > "$LAB/state/.watch-cycle-exits.log"
bin/fm-watch-arm.sh > "$LAB/armA.out" 2>&1 & APID=$!
# wait until the watcher (child of arm A) runs the real python herdr-eventwait reader
for i in $(seq 1 300); do
  W=$(pgrep -P "$APID" -f fm-watch.sh | head -1)
  [ -n "$W" ] && pgrep -f "herdr-eventwait.py.*$S" >/dev/null && break
  sleep 0.1
done
W=$(pgrep -P "$APID" -f fm-watch.sh | head -1)
echo "armA=$APID watcher=$W; reader: $(pgrep -fl "herdr-eventwait.py.*$S" | head -1)"
sleep 1   # well inside the 15s event wait
T0=$(date +%s)
bin/fm-watch-arm.sh --take-over "$APID" > "$LAB/takeover.out" 2>&1 & TPID=$!
# take-over owning a fresh cycle stays alive; a failing one exits
for i in $(seq 1 300); do
  if grep -q "watcher_pid=$W	origin=attached	" "$LAB/state/.watch-cycle-exits.log" 2>/dev/null; then
    TK=$(date +%s); sleep 0.5; echo "take-over closed old watcher after $((TK-T0))s; marker right after handover: $(cat "$LAB/state/.watcher-down" 2>/dev/null)"; break
  fi
  kill -0 "$TPID" 2>/dev/null || break
  sleep 0.1
done
sleep 3
T1=$(date +%s)
echo "--- elapsed since take-over: $((T1-T0))s; old watcher alive: $(kill -0 $W 2>/dev/null && echo yes || echo no); take-over arm alive: $(kill -0 $TPID 2>/dev/null && echo yes || echo no); arm A alive: $(kill -0 $APID 2>/dev/null && echo yes || echo no)"
NEWW=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
echo "lock now: $(cat "$LAB/state/.watch.lock/pid" 2>/dev/null | tr '\t' ' ')"
echo "new watcher parent: $(ps -o ppid= -p "${NEWW%% *}" 2>/dev/null | tr -d ' ') (take-over arm=$TPID)"
echo "--- wake queue:"; cat "$LAB/state/.wake-queue" 2>/dev/null | tail -5
echo "--- .watcher-down:"; cat "$LAB/state/.watcher-down" 2>/dev/null || echo "(absent)"
echo "--- take-over arm output:"; cat "$LAB/takeover.out"
echo "--- arm A output:"; cat "$LAB/armA.out"
echo "--- .watch-cycle-exits.log:"; cat "$LAB/state/.watch-cycle-exits.log" 2>/dev/null
