#!/usr/bin/env bash
# drive.sh <label> [stall_bound_for_takeover]
set -u
W=/Users/mtanzi/.no-mistakes/worktrees/233970cc3bb4/01M5N3SA9JW86ZB22WD85463HB
label=$1; takeover_stall=${2:-}
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/fakebin"
printf 'project=demo\nwindow=default:w1:p1\nbackend=herdr\nharness=claude\n' > "$LAB/state/demo.meta"
cat > "$LAB/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'session list --json' ] || exit 1
printf '{"sessions":[{"name":"default","socket_path":"/nonexistent/herdr.sock"}]}\n'
SH
cat > "$LAB/fakebin/fake-eventwait" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
if [ -e "$FM_HOME/eventwait.block" ] && d=$(cat "$FM_HOME/eventwait.block") && rm "$FM_HOME/eventwait.block" 2>/dev/null; then
  : > "$FM_HOME/eventwait.blocking"; sleep "$d"
else
  sleep "$2"
fi
SH
chmod +x "$LAB/fakebin/"*
export FM_HOME=$LAB PATH="$LAB/fakebin:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_BACKEND_HERDR_EVENT_READER="$LAB/fakebin/fake-eventwait"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ts() { python3 -c 'import time;print("%.1f"%time.time())'; }
"$W/bin/fm-watch-arm.sh" > "$LAB/armA.out" 2>&1 &
ARM_A=$!
for _ in $(seq 100); do [ -s "$LAB/state/.watch.lock/pid" ] && grep -q started "$LAB/armA.out" && break; sleep 0.1; done
WATCHER=$(cat "$LAB/state/.watch.lock/pid")
echo "[$label] arm A pid=$ARM_A, its watcher pid=$WATCHER (ppid=$(ps -o ppid= -p "$WATCHER" | tr -d ' '))"; cat "$LAB/armA.out"
printf 'acked:downtime:seed.1.prior\n' > "$LAB/state/.watcher-down"  # main acked the previous episode
echo "${BLOCK:-12}" > "$LAB/eventwait.block"
for _ in $(seq 400); do [ -e "$LAB/eventwait.blocking" ] && break; sleep 0.1; done
[ -e "$LAB/eventwait.blocking" ] && echo "[$label] watcher is inside a ${BLOCK:-12}s herdr event wait (command substitution)" || echo "[$label] fixture: never blocked"
T0=$(ts)
( [ -n "$takeover_stall" ] && export FM_WATCHER_STALL_BOUND=$takeover_stall; if [ "${MODE:-takeover}" = stop ]; then exec "$W/bin/fm-watch-arm.sh" --stop; else exec "$W/bin/fm-watch-arm.sh" --take-over "$ARM_A"; fi ) > "$LAB/armB.out" 2>&1 &
ARM_B=$!
gone=""
for _ in $(seq 600); do
  if [ -z "$gone" ] && ! kill -0 "$WATCHER" 2>/dev/null; then gone=$(ts); fi
  if [ -z "${b_out:-}" ] && [ -s "$LAB/armB.out" ]; then b_out=$(ts); echo "[$label] arm B first status line at t=$(python3 -c "print('%.1f'%($b_out-$T0))")s, watcher alive: $(kill -0 "$WATCHER" 2>/dev/null && echo yes || echo no)"; fi
  [ -n "$gone" ] && [ -s "$LAB/state/.watch.lock/pid" ] && [ "$(cat "$LAB/state/.watch.lock/pid")" != "$WATCHER" ] && break
  sleep 0.1
done
sleep 2
NEW=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
echo "[$label] take-over arm B pid=$ARM_B started at t=0; left watcher exited at t=$(python3 -c "print('%.1f'%($gone-$T0))" 2>/dev/null)s"
echo "[$label] arm B output:"; sed 's/^/    /' "$LAB/armB.out"
echo "[$label] lock now pid=$NEW parent=$(ps -o ppid= -p "$NEW" 2>/dev/null | tr -d ' ') (arm B=$ARM_B)"
echo "[$label] .watcher-down: $(cat "$LAB/state/.watcher-down" 2>/dev/null || echo '<absent>')"
echo "[$label] cycle ledger (reason/disposition columns):"
cat "$LAB/state/.watch-cycle-exits.log" | sed 's/^/    /'
kill "$ARM_B" "$ARM_A" 2>/dev/null; pkill -P "$ARM_B" 2>/dev/null; sleep 1
for p in $(cat "$LAB/state/.watch.lock/pid" 2>/dev/null); do kill "$p" 2>/dev/null; done
cp -R "$LAB/state" /tmp/fmlive/state-$label 2>/dev/null; sleep 1; rm -rf "$LAB"; echo "[$label] lab removed"
