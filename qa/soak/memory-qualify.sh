#!/usr/bin/env bash
# Memory qualification — sample protocol-mapper RSS / FDs / CPU / MQTT rate
# under steady-state load and compute a linear-regression growth rate.
#
# Decides between "warmup heap growth that stabilises" and "sustained leak"
# by split-half analysis: if the second-half slope is much lower than the
# first-half, the process is converging.
#
# Usage:
#   ./qa/soak/memory-qualify.sh                       # defaults: 30 min, 60 s samples
#   DURATION_MIN=10 ./qa/soak/memory-qualify.sh       # quick 10-min sanity run
#   SAMPLE_INTERVAL_S=30 ./qa/soak/memory-qualify.sh  # 30-s samples
#
# Prerequisites:
#   - PM container running with code under test loaded (bind-mount or rebuilt).
#   - SCFs deployed and the data plane flowing (verify with a quick mosquitto_sub).
#   - python3 + jq available on host.

set -uo pipefail

DURATION_MIN="${DURATION_MIN:-30}"
SAMPLE_INTERVAL_S="${SAMPLE_INTERVAL_S:-60}"
WARMUP_S="${WARMUP_S:-60}"
PM_CONTAINER="${PM_CONTAINER:-platform-protocol-mapper-1}"
BROKER_HOST="${BROKER_HOST:-172.18.0.11}"
BROKER_PORT="${BROKER_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"
MQTT_PASS="${MQTT_PASS:-admin}"
OUT="${OUT:-/tmp/mem_qualify_$(date +%Y%m%d_%H%M%S).csv}"

N_SAMPLES=$(( DURATION_MIN * 60 / SAMPLE_INTERVAL_S ))
PROBE_S=4
SLEEP_S=$(( SAMPLE_INTERVAL_S - PROBE_S - 3 ))

echo "=== Memory qualification ==="
echo "  PM container:     $PM_CONTAINER"
echo "  broker:           $BROKER_HOST:$BROKER_PORT"
echo "  duration:         $DURATION_MIN min  ($N_SAMPLES samples every ${SAMPLE_INTERVAL_S}s)"
echo "  warmup:           ${WARMUP_S}s"
echo "  output CSV:       $OUT"
echo ""

# Sanity: PM container exists and is running
state=$(docker inspect "$PM_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo missing)
[[ "$state" != "running" ]] && { echo "ERROR: $PM_CONTAINER is $state, expected running"; exit 1; }

echo "t_s,rss_kb,fd,cpu_pct,msg_per_s" > "$OUT"
echo "[$(date +%H:%M:%S)] warmup ${WARMUP_S}s..."
sleep "$WARMUP_S"

START=$(date +%s)
for i in $(seq 1 "$N_SAMPLES"); do
  T=$(( $(date +%s) - START ))
  RSS=$(docker exec "$PM_CONTAINER" sh -c 'awk "/VmRSS/{print \$2}" /proc/$(pgrep -of node)/status' 2>/dev/null)
  FD=$(docker exec "$PM_CONTAINER" sh -c 'ls /proc/$(pgrep -of node)/fd | wc -l' 2>/dev/null)
  CPU=$(docker stats --no-stream --format '{{.CPUPerc}}' "$PM_CONTAINER" 2>/dev/null | tr -d '%')
  MSGS=$(timeout "$((PROBE_S + 1))" mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t 'services/#' -W "$PROBE_S" 2>/dev/null | wc -l)
  MSG_PS=$(( MSGS / PROBE_S ))
  echo "${T},${RSS},${FD},${CPU},${MSG_PS}" >> "$OUT"
  printf "[%s] sample %2d/%d  t=%4ds  rss=%6s kB  fd=%3s  cpu=%5s%%  msg/s=%4s\n" \
    "$(date +%H:%M:%S)" "$i" "$N_SAMPLES" "$T" "$RSS" "$FD" "$CPU" "$MSG_PS"
  [[ $i -lt $N_SAMPLES ]] && sleep "$SLEEP_S"
done

echo ""
echo "=== LINEAR REGRESSION + SPLIT-HALF ANALYSIS ==="
python3 - "$OUT" << 'PYEOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
N = len(rows)
ts   = [int(r['t_s'])   for r in rows]
rsss = [int(r['rss_kb']) for r in rows]
fds  = [int(r['fd'])    for r in rows]

def fit(xs, ys):
    n = len(xs); mx = sum(xs)/n; my = sum(ys)/n
    num = sum((xs[i]-mx)*(ys[i]-my) for i in range(n))
    den = sum((xs[i]-mx)**2 for i in range(n))
    return num/den if den else 0.0

slope = fit(ts, rsss)
half  = N // 2
s_early = fit(ts[:half], rsss[:half])
s_late  = fit(ts[half:], rsss[half:])

print(f"samples       : {N}")
print(f"span          : {ts[-1]}s ({ts[-1]/60:.1f} min)")
print(f"RSS first     : {rsss[0]:>8} kB")
print(f"RSS last      : {rsss[-1]:>8} kB")
print(f"RSS delta     : {rsss[-1]-rsss[0]:+8} kB")
print(f"RSS min/max   : {min(rsss):>8} / {max(rsss)} kB  (range {max(rsss)-min(rsss)} kB)")
print(f"FD min/max    : {min(fds)} / {max(fds)}   {'STABLE' if min(fds)==max(fds) else 'CHANGED'}")
print(f"")
print(f"overall slope : {slope*60:+8.1f} kB/min  ({slope*3600/1024:+.2f} MB/hr)")
print(f"first-half    : {s_early*60:+8.1f} kB/min")
print(f"second-half   : {s_late*60:+8.1f} kB/min")
print(f"")
ratio = abs(s_late)/abs(s_early) if s_early else 0
if abs(s_late) < 5 and abs(slope) < 50:
    verdict = "NO LEAK (steady state, growth < 5 kB/min in second half)"
elif s_late < s_early * 0.3:
    verdict = "WARMUP GROWTH (second-half converging to steady state)"
elif s_late > 0 and s_late >= s_early * 0.7:
    verdict = "POSSIBLE LEAK (sustained growth — investigate)"
else:
    verdict = "INCONCLUSIVE — extend duration"
print(f"VERDICT       : {verdict}")
PYEOF
