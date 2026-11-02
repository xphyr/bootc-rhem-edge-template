#!/bin/bash
# greenboot health check: critical base-image services must be running and stable.
#
# In wanted.d: a failure is logged (journalctl -u greenboot-healthcheck) but
# does not trigger a reboot or rollback. Move it to required.d (and update the
# chmod in the Containerfile) once you trust it, so a broken flightctl-agent or
# alloy makes greenboot roll the device back. Read the rollback notes in
# docs/base-image-pipeline.md first.
#
# Both services use Restart=always, so a broken one cycles between starting
# and failing rather than staying failed. The check waits for each service to
# become active, then confirms it is still active with the same main PID after
# a settle period, which catches restart loops.
set -u

SERVICES=(flightctl-agent alloy)
START_TIMEOUT=120   # seconds to wait for all services to become active
SETTLE=30           # seconds a service must stay up without restarting

fail=0
deadline=$((SECONDS + START_TIMEOUT))
declare -A pid

for svc in "${SERVICES[@]}"; do
    until systemctl is-active --quiet "$svc"; do
        if (( SECONDS >= deadline )); then
            echo "FAIL: $svc not active after ${START_TIMEOUT}s (state: $(systemctl is-active "$svc"))" >&2
            fail=1
            continue 2
        fi
        sleep 5
    done
    pid[$svc]=$(systemctl show -P MainPID "$svc")
done

sleep "$SETTLE"

for svc in "${!pid[@]}"; do
    now=$(systemctl show -P MainPID "$svc")
    if ! systemctl is-active --quiet "$svc"; then
        echo "FAIL: $svc stopped within ${SETTLE}s of starting (state: $(systemctl is-active "$svc"))" >&2
        fail=1
    elif [[ $now != "${pid[$svc]}" ]]; then
        echo "FAIL: $svc restarted within ${SETTLE}s (PID ${pid[$svc]} -> $now)" >&2
        fail=1
    else
        echo "OK: $svc active (PID $now)"
    fi
done

exit "$fail"
