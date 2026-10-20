#!/bin/bash
# /usr/local/bin/installhermes-entrypoint — v8 PID 1 supervisor (NO s6-overlay)
#
# WHY THIS EXISTS (2026-10-20, 5 rejected Fred leases):
#   The base image's s6-overlay v3 boot chain runs
#   preinit → stage0 → `s6-linux-init-maker -c /run/s6/basedir` (GENERATES the
#   init binary INTO /run at boot) → `exec /run/s6/basedir/bin/init`.
#   Fred's tenant sandbox denies exec of files under /run. Every lease died
#   identically in <10s: "stage0: 83: exec: /run/s6/basedir/bin/init:
#   Permission denied", exit 126 (Manifest container logs, leases 01a156ce /
#   01a156d8 / 01a1573d / 01a15774 / 01a15778, backends docker-10 and
#   docker-13, images 2026.10.20.050 → .339). Plain Docker, docker --init, and
#   a faithful tenant-seccomp profile all boot the same image fine — seccomp
#   cannot filter by path; the /run exec denial is mount/LSM level.
#
#   s6-overlay v3 structurally CANNOT boot under that sandbox. So this
#   entrypoint replaces the whole s6 chain: it is PID 1, it runs the SAME
#   cont-init scripts from the image layer, starts the SAME services with the
#   SAME privilege drops, and supervises them. NOTHING EVER EXECUTES FROM
#   /run. (The everclaw/IOC images have run this way on Fred since launch —
#   18/18 warm buffers.)
#
# Boot sequence:
#   Phase 1  cont-init (root, image layer):
#              /etc/cont-init.d/01-hermes-setup     upstream stage2 hook:
#                UID/GID remap, /opt/data bootstrap, .env seed (API_SERVER_KEY
#                generation), browser path, skills sync. MUST succeed —
#                a failed bootstrap aborts the container (Fred parity: s6
#                aborts on cont-init failure).
#              /etc/cont-init.d/02-installhermes-config.sh  (ours) headless
#                hermes config + dashboard invariants. MUST succeed.
#              /etc/cont-init.d/02-reconcile-profiles  BEST-EFFORT only: it
#                reconciles s6-registered per-profile gateway services; with
#                no s6 runtime there is nothing to reconcile, and the upstream
#                Python wrapper warns-and-continues on a missing scandir.
#   Phase 2  with-contenv equivalent: every file in /run/s6/container_environment
#              is exported as env (that dir is exactly what upstream's
#              with-contenv reads; 01-hermes-setup writes the browser path
#              there, our 02 writes the dashboard invariants there).
#   Phase 3  services (privilege-dropped via s6-setuidgid, which lives in the
#              IMAGE LAYER at /command — executing it is fine; only /run
#              execs are denied):
#              auth-proxy   :18789  0.0.0.0   the ONLY ingress (Privy JWT front)
#              dashboard    :9119   127.0.0.1 hermes dashboard (Chat surface)
#              cig-adapter  :18900  127.0.0.1 loopback CIG inference shim
#            No gateway process: upstream `gateway run` is the MESSAGING-gateway
#            invocation and exits when no channels are configured (v2-v5
#            history); the dashboard provides the product chat surface. The
#            loopback api_server :8642 is therefore NOT expected to listen.
#   Phase 4  supervise: wait/restart loop with per-service backoff. PID 1 never
#            exits on its own while services are restartable. Our services are
#            single-process exec chains (node / python — no daemonizing,
#            no double-fork), so `wait` reaps everything they spawn that is a
#            bash job; orphaned grandchildren are the runtime's problem on
#            container stop (docker stop kills the whole cgroup).
#
# Env contract: identical to v7 (see README.md "Container environment
# contract"). Docker env reaches PID 1 intact — no /init env scrubbing, so
# no with-contenv rehydration is needed for the Docker-provided vars. The
# with-contenv shebangs on the cont-init scripts are bypassed (we run them
# via `sh`), which is CORRECT here: the env they would rehydrate is already
# present.

set -u
shopt -s nullglob   # empty-dir globs vanish instead of expanding to a literal

log() { printf '[installhermes] %s\n' "$*"; }

S6_SETUIDGID="$(command -v s6-setuidgid || true)"
if [ -z "$S6_SETUIDGID" ]; then
  for cand in /command/s6-setuidgid /usr/local/bin/s6-setuidgid /package/admin/s6-overlay/command/s6-setuidgid; do
    if [ -x "$cand" ]; then S6_SETUIDGID="$cand"; break; fi
  done
fi
if [ -z "$S6_SETUIDGID" ]; then
  log "FATAL: s6-setuidgid not found (expected in the base image at /command)"
  exit 111
fi

# ---------------------------------------------------------------- Phase 1 ---
run_continit() {
  # MUST-SUCCEED scripts: a failure here is a broken bootstrap → abort the
  # container (exit non-zero, Fred rejects the lease — same contract s6 gave).
  local script rc
  for script in /etc/cont-init.d/01-hermes-setup \
                /etc/cont-init.d/02-installhermes-config.sh; do
    if [ ! -x "$script" ]; then
      log "FATAL: cont-init script missing or not executable: $script"
      exit 112
    fi
    log "cont-init: running $script"
    if ! sh "$script"; then
      rc=$?
      log "FATAL: cont-init failed ($script, exit $rc) — aborting (bootstrap contract)"
      exit 112
    fi
  done

  # BEST-EFFORT: the profile reconciler exists to restore s6-registered
  # per-profile gateways; without an s6 runtime there is nothing to restore.
  # Upstream's wrapper warns-and-continues on a missing scandir, but any
  # non-zero here must NOT kill a perfectly bootable hosted container.
  local rec=/etc/cont-init.d/02-reconcile-profiles
  if [ -x "$rec" ]; then
    log "cont-init (best-effort): running $rec"
    if ! sh "$rec"; then
      rc=$?
      log "WARN: $rec exited $rc — no s6 runtime, profile gateways unavailable (expected)"
    fi
  fi
}

# ---------------------------------------------------------------- Phase 2 ---
load_container_environment() {
  # with-contenv equivalent: /run/s6/container_environment files are
  # KEY-by-filename, value-by-content. Writing files under /run is allowed
  # on Fred; only EXECUTING from /run is denied.
  local dir=/run/s6/container_environment f k
  if [ -d "$dir" ]; then
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      k="$(basename "$f")"
      export "$k=$(cat "$f" 2>/dev/null || true)"
    done
  fi
}

# ---------------------------------------------------------------- Phase 3 ---
# Product invariants (enforced AFTER loading container_environment so a
# manifest cannot silently turn the dashboard off or expose it non-loopback):
# the dashboard is ALWAYS on, ALWAYS loopback — the auth-proxy is the only
# ingress; a non-loopback dashboard bind would engage the dashboard's own auth
# gate and expose an unauthenticated surface behind it.
export HERMES_DASHBOARD=1
export HERMES_DASHBOARD_HOST=127.0.0.1
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"

declare -A PIDS=()    # service name -> pid
declare -A FAILS=()   # service name -> consecutive failed starts
declare -A STAMP=()   # service name -> last start epoch (backoff reset)

svc_pid_ok() { kill -0 "${PIDS[$1]:-999999}" 2>/dev/null; }

spawn_service() {
  local name="$1" pid
  case "$name" in
    auth-proxy)
      HOME=/opt/data "$S6_SETUIDGID" hermes /usr/local/bin/auth-proxy &
      ;;
    dashboard)
      # Upstream s6-rc.d/dashboard/run contract: HOME anchored to /opt/data
      # (with-contenv repopulates HOME as /root — upstream resets it before
      # the privilege drop), cwd /opt/data, loopback bind, --no-open.
      # `exec` as the subshell's last command: the & child IS
      # s6-setuidgid→hermes (single process), so TERM reaches the service
      # directly (a bare subshell would swallow the signal and orphan it).
      ( cd /opt/data; HOME=/opt/data exec "$S6_SETUIDGID" hermes hermes dashboard \
          --host "$HERMES_DASHBOARD_HOST" --port "$HERMES_DASHBOARD_PORT" --no-open ) &
      ;;
    cig-adapter)
      HOME=/opt/data "$S6_SETUIDGID" hermes /usr/local/bin/cig-adapter &
      ;;
    *)
      log "FATAL: unknown service $name"
      exit 113
      ;;
  esac
  pid=$!
  PIDS[$name]=$pid
  STAMP[$name]=$(date +%s)
  log "service $name started (pid $pid)"
}

had_stable_uptime() { # true when the service had been up ≥300s → reset backoff
  local now
  now=$(date +%s)
  [ $((now - ${STAMP[$1]:-0})) -ge 300 ]
}

backoff_seconds() { # 2,4,8,16,32,64 — capped
  local n=${FAILS[$1]:-1}
  [ "$n" -gt 6 ] && n=6
  echo $((2 ** n))
}

supervise() {
  # Trap is installed ONCE in main (before cont-init) so SIGTERM/SIGINT during
  # ANY phase — bootstrap, env load, spawn, supervision — runs shutdown():
  # PID 1 must never take a default-killed exit while children exist.
  local name delay rc
  while :; do
    # wait -n wakes on ANY child exit (or a trapped signal; the trap then
    # runs shutdown and exits the container). Its rc is the exit status of
    # ONE exited child; if several died in one wake, later ones log "rc
    # unknown" — supervision behavior is unaffected.
    wait -n
    rc=$?
    for name in auth-proxy dashboard cig-adapter; do
      [ -n "${PIDS[$name]:-}" ] || continue
      svc_pid_ok "$name" && continue
      log "service $name (pid ${PIDS[$name]}) exited (rc $rc)"
      unset "PIDS[$name]"
      if had_stable_uptime "$name"; then
        FAILS[$name]=1
      else
        FAILS[$name]=$(( ${FAILS[$name]:-0} + 1 ))
      fi
      delay=$(backoff_seconds "$name")
      log "service $name: restart #$(( ${FAILS[$name]:-1} )) in ${delay}s"
      sleep "$delay"
      spawn_service "$name"
    done
  done
}

shutdown() {
  local pid name i alive
  log "SIGTERM/SIGINT — stopping services"
  for pid in "${PIDS[@]}"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    alive=0
    for pid in "${PIDS[@]}"; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    [ "$alive" = 0 ] && break
    sleep 1
  done
  for pid in "${PIDS[@]}"; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  done
  log "all services stopped — exiting"
  exit 0
}

# ------------------------------------------------------------------ main ---
[ "$(id -u)" = 0 ] || log "NOTE: starting as uid $(id -u) (non-root start; privilege drops still apply where possible)"

log "v8 entrypoint starting (no s6; pid 1 supervisor)"
# Install the shutdown trap BEFORE any work begins: a SIGTERM arriving during
# cont-init, env load, or the first spawns must still run shutdown() — a
# default-killed PID 1 would abandon already-started children mid-boot
# (R1 audit catch; s6 parity: /init always owned signals from the first exec).
trap 'shutdown' TERM INT
run_continit
load_container_environment
# Re-assert invariants AFTER the container_environment load (a file written by
# cont-init could carry a stale/manifest-supplied host; the product contract
# wins — the dashboard is always on, always loopback).
export HERMES_DASHBOARD=1
export HERMES_DASHBOARD_HOST=127.0.0.1

log "starting services: auth-proxy dashboard cig-adapter"
spawn_service auth-proxy
spawn_service dashboard
spawn_service cig-adapter
supervise
