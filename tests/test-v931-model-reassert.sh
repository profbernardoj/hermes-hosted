#!/bin/sh
# v9.3.1 local harness — regression test for the 02-installhermes-config.sh
# model re-assert, against the REAL production corruption shapes captured
# from live lease 01a166bd (hermes-hosted:2026.10.22.307, Oct 23 outage).
#
# Cases:
#   A. PRODUCTION CORRUPT (v9.3.0 output on the template-seeded file):
#      scalar model line followed by orphaned template children.
#   B. LEGACY NESTED (pre-v9.3.0 script's own form / upstream template
#      as-seeded): bare `model:` header + indented children.
#   C. CLEAN SCALAR (v9.3.1 output / our starter after runtime rewrite):
#      value swap, no orphans, surrounding config preserved.
#   D. NO MODEL KEY AT ALL: append at... (documented behavior: appended
#      after last line — same as v9.3.0).
#   E. NON-MODEL nested `default:` keys elsewhere must SURVIVE.
#   F. Idempotency: running the fixed script on its own output is a no-op.
#
# Every case asserts: output parses as YAML (python3+PyYAML) AND the
# top-level `model` key equals deepseek-v4-flash-0731 AND (case E) the
# unrelated `  default:` child survives.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cont-init.d/02-installhermes-config.sh"
DM="deepseek-v4-flash-0731"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

run_case() { # name fixture
  name="$1"; fix="$2"; out="$TMP/$name.out"
  mkdir -p "$TMP/$name.home"
  cp "$fix" "$TMP/$name.home/config.yaml"
  # emulate the script's environment (only the re-assert branch runs:
  # the fixture never contains the marker)
  ( cd / && HERMES_HOME="$TMP/$name.home" AGENT_NAME="TestBot" \
      sh "$SCRIPT" ) > "$TMP/$name.log" 2>&1
}

check() { # name expect_extra
  name="$1"
  if python3 - "$TMP/$name.home/config.yaml" "$DM" <<'PY'
import sys, yaml
path, dm = sys.argv[1], sys.argv[2]
with open(path) as f:
    doc = yaml.safe_load(f)
assert isinstance(doc, dict), "not a mapping"
assert doc.get("model") == dm, f"model={doc.get('model')!r}"
PY
  then :; else echo "FAIL($name): YAML invalid or model wrong"; FAIL=1; return; fi
}

# ---------- Case A: production corrupt (scalar + orphans) ----------
cat > "$TMP/a.yaml" <<'EOF'
# Hermes Agent CLI Configuration
_config_version: 50

# =============================================================================
# Model Configuration
# =============================================================================
model: deepseek-v4-flash-0731
  # Default model to use (can be overridden with --model flag)
  # Both "default" and "model" work as the key name here.
  default: "anthropic/claude-opus-4.6"

  # Inference provider selection:
  #   "auto"         - Auto-detect from credentials (default)
  provider: "auto"

personality:
  name: Sunflower
EOF
run_case a "$TMP/a.yaml"
check a
if grep -q 'default: "anthropic' "$TMP/a.home/config.yaml"; then
  echo "FAIL(a): orphaned default survived"; FAIL=1
fi
if ! grep -q 'personality:' "$TMP/a.home/config.yaml"; then
  echo "FAIL(a): personality lost"; FAIL=1
fi
# double-apply (idempotency on the repaired shape) — case F folded in
run_case a2 "$TMP/a.home/config.yaml"; check a2

# ---------- Case B: legacy nested header form ----------
cat > "$TMP/b.yaml" <<'EOF'
_config_version: 50
model:
  # Default model to use
  default: "anthropic/claude-opus-4.6"
  provider: "auto"
personality:
  name: Sunflower
EOF
run_case b "$TMP/b.yaml"
check b
if grep -q 'anthropic/claude' "$TMP/b.home/config.yaml"; then
  echo "FAIL(b): template default survived"; FAIL=1
fi

# ---------- Case C: clean scalar value swap ----------
cat > "$TMP/c.yaml" <<'EOF'
_config_version: 50
model: anthropic/claude-opus-4.6
personality:
  name: Sunflower
EOF
run_case c "$TMP/c.yaml"
check c

# ---------- Case D: no model key ----------
cat > "$TMP/d.yaml" <<'EOF'
_config_version: 50
personality:
  name: Sunflower
EOF
run_case d "$TMP/d.yaml"
check d

# ---------- Case E: unrelated nested default: must survive ----------
cat > "$TMP/e.yaml" <<'EOF'
model: anthropic/claude-opus-4.6
routing:
  strategy: round-robin
  default: pick-first
personality:
  name: Sunflower
EOF
run_case e "$TMP/e.yaml"
check e
if ! grep -q 'default: pick-first' "$TMP/e.home/config.yaml"; then
  echo "FAIL(e): unrelated nested default was dropped"; FAIL=1
fi
if grep -q 'pick-first' "$TMP/e.home/config.yaml" && python3 - "$TMP/e.home/config.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc["routing"]["default"] == "pick-first", "routing.default mangled"
PY
then :; else echo "FAIL(e): routing.default wrong after rewrite"; FAIL=1; fi

# ---------- Case F: model block at EOF (no trailing key) ----------
printf '_config_version: 50\nmodel:\n  default: "anthropic/claude-opus-4.6"\n' > "$TMP/f.yaml"
run_case f "$TMP/f.yaml"
check f

# ---------- Case G: TAB-indented orphans (Grok R1 #1 regression) ----------
printf '_config_version: 50\nmodel: "deepseek-v4-flash-0731"\n\tdefault: "anthropic/claude-opus-4.6"\n\tprovider: "auto"\npersonality:\n  name: Sunflower\n' > "$TMP/g.yaml"
run_case g "$TMP/g.yaml"
check g
if grep -q 'anthropic/claude' "$TMP/g.home/config.yaml"; then
  echo "FAIL(g): tab-indented orphan survived"; FAIL=1
fi

# ---------- Case H: fresh/marker branch (regenerated config) ----------
mkdir -p "$TMP/h.home"
printf '# Managed by hermes-hosted (installhermes.ai) — regenerated at boot.\nmodel: "whatever"\npersonality:\n  name: "Old"\n' > "$TMP/h.home/config.yaml"
( cd / && HERMES_HOME="$TMP/h.home" AGENT_NAME='Weird: Name #1' \
    sh "$SCRIPT" ) > "$TMP/h.log" 2>&1
if ! python3 - "$TMP/h.home/config.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc["model"] == "deepseek-v4-flash-0731", doc["model"]
# v9.3.1 deletes only quotes/backslashes/newlines: : and # survive
assert doc["personality"]["name"] == "Weird: Name #1", doc["personality"]
PY
then echo "FAIL(h): fresh branch YAML invalid or values wrong"; FAIL=1
fi

if [ "$FAIL" = 0 ]; then
  echo "ALL CASES PASS (A production-corrupt, B legacy-nested, C scalar-swap, D append, E unrelated-default-preserved, F block-at-EOF, G tab-orphans, H fresh-branch-YAML-safe-names, A2 idempotent)"
else
  echo "HARNESS FAILURES — see above"; exit 1
fi

# ---------- Case I: hostile AGENT_NAME in fresh branch (Opus R1 #1) ----------
mkdir -p "$TMP/i.home"
rm -f "$TMP/i.home/config.yaml"
( cd / && HERMES_HOME="$TMP/i.home" AGENT_NAME='Dr. "Bo\t\\t" #1' \
    sh "$SCRIPT" ) > "$TMP/i.log" 2>&1
if ! python3 - "$TMP/i.home/config.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc["model"] == "deepseek-v4-flash-0731"
assert isinstance(doc.get("personality", {}).get("name"), str)
PY
then echo "FAIL(i): hostile name broke fresh config"; FAIL=1
fi

# ---------- Case J: duplicate top-level model keys (Opus nonblocking) ----------
cat > "$TMP/j.yaml" <<'EOF'
_config_version: 50
model: anthropic/claude-opus-4.6
toolsets:
  - hermes-cli
model: openai/gpt-4o
personality:
  name: Sunflower
EOF
run_case j "$TMP/j.yaml"
check j
if [ "$(grep -c '^model:' "$TMP/j.home/config.yaml")" != 1 ]; then
  echo "FAIL(j): duplicate model keys remain"; FAIL=1
fi

# ---------- Case K: col-1 comment inside nested block (Opus nonblocking) ----------
cat > "$TMP/k.yaml" <<'EOF'
_config_version: 50
model:
# column one comment inside the block
  default: "anthropic/claude-opus-4.6"
personality:
  name: Sunflower
EOF
run_case k "$TMP/k.yaml"
check k
if ! grep -q 'name: Sunflower' "$TMP/k.home/config.yaml"; then
  echo "FAIL(k): personality lost"; FAIL=1
fi
[ "$FAIL" = 0 ] && echo "EXTRA CASES PASS (I hostile-name, J dup-model, K col1-comment-in-block)" || exit 1

# ---------- Case L: CJK name survives (Opus R2 NB2 — David's agent is ひまわり) ----------
mkdir -p "$TMP/l.home"; rm -f "$TMP/l.home/config.yaml"
( cd / && HERMES_HOME="$TMP/l.home" AGENT_NAME='ひまわり' sh "$SCRIPT" ) > "$TMP/l.log" 2>&1
if ! python3 - "$TMP/l.home/config.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc["personality"]["name"] == "ひまわり", repr(doc["personality"]["name"])
assert doc["model"] == "deepseek-v4-flash-0731"
PY
then echo "FAIL(l): CJK name did not survive"; FAIL=1
fi

# ---------- Case M: newline in AGENT_NAME (Opus R2 NB1) ----------
mkdir -p "$TMP/m.home"; rm -f "$TMP/m.home/config.yaml"
( cd / && HERMES_HOME="$TMP/m.home" AGENT_NAME='Bad
Name' sh "$SCRIPT" ) > "$TMP/m.log" 2>&1
if ! python3 - "$TMP/m.home/config.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc["model"] == "deepseek-v4-flash-0731"
PY
then echo "FAIL(m): newline name broke fresh config"; FAIL=1
fi
[ "$FAIL" = 0 ] && echo "FINAL CASES PASS (L cjk-name, M newline-name)" || exit 1
