#!/usr/bin/env bash
# yolo-guard.sh — PreToolUse enforcement for `claude --dangerously-skip-permissions`.
#
# Registered in .claude/settings.json under hooks.PreToolUse with matcher "Bash",
# so it receives only Bash tool calls. It reads the tool-call JSON on stdin and,
# on a dangerous match, emits a `permissionDecision: "deny"`. Per the Claude Code
# hooks reference, a hook "deny" blocks the tool EVEN in bypassPermissions mode /
# with --dangerously-skip-permissions. Source: code.claude.com/docs/en/hooks-guide
#
# Design notes:
#   - Fail CLOSED: if the environment is wrong (no jq) the hook blocks rather than
#     silently allowing. A PreToolUse hook that always exits 0 is a no-op.
#   - This is the place for ARGUMENT-SHAPE checks (pipe-to-shell, .env reads) that
#     settings.json globs cannot express reliably.
#   - Pattern matching is best-effort against a cooperative agent, not an adversary.
#     The real containment boundary is a container/VM, not this script.
#   - Catastrophic `rm` TARGETS are blocked; a routine `rm -rf node_modules` is allowed
#     so normal dev flow is not interrupted. Tune to taste.

set -uo pipefail

# --- Fail closed if jq is unavailable ---------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "yolo-guard: jq is required but not installed; blocking by default." >&2
  exit 2
fi

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"

# No command string -> nothing to evaluate, allow.
[ -z "$cmd" ] && exit 0

# Collapse whitespace/newlines so multi-line and spaced commands match cleanly.
norm="$(printf '%s' "$cmd" | tr '\n\t' '  ' | tr -s ' ')"

deny() {
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Case-insensitive, extended-regex match against the whole (normalized) command.
m() { printf '%s' "$norm" | grep -Eiq -- "$1"; }

# --- Privilege / system mutation --------------------------------------------
m '(^|[^[:alnum:]_/.])sudo([[:space:]]|$)'                  && deny "sudo is blocked under YOLO mode."
m '(^|[[:space:]])(pacman|yay)([[:space:]]+-(S|R|U)|[[:space:]])' && deny "System package changes (pacman/yay) are blocked."
m 'chmod[[:space:]]+(-[a-z]*R[a-z]*[[:space:]]+)?0?777'     && deny "chmod 777 is blocked."

# --- Catastrophic deletes (targets, not all rm -rf) -------------------------
# Built-in circuit breakers already stop `rm -rf /` and `rm -rf ~`; this widens it.
m 'rm[[:space:]]+(-[a-z]*[rf][a-z]*[[:space:]]+)+(/|~|\$HOME|/\*)([[:space:]]|/|$)' \
  && deny "Refusing recursive delete of /, ~, \$HOME, or /*."
m 'rm[[:space:]]+(-[a-z]*[rf][a-z]*[[:space:]]+)+(\.|\.\.|\*)([[:space:]]|$)' \
  && deny "Refusing recursive delete of '.', '..', or '*'."

# --- Git: remote / history safety -------------------------------------------
m 'git[[:space:]]+push([[:space:]].*)?(--force([[:space:]]|=|$)|[[:space:]]-f([[:space:]]|$))' \
  && deny "Force-push is blocked. Rebase/merge, then push without --force."
m 'git[[:space:]]+reset[[:space:]]+--hard'                  && deny "git reset --hard is blocked."
m 'git[[:space:]]+clean[[:space:]]+-[a-z]*f'                && deny "git clean -f* wipes untracked files; blocked."
m '(filter-branch|filter-repo|git[[:space:]]+push[[:space:]].*--mirror)' \
  && deny "Git history rewrite / mirror push is blocked."

# --- Download-and-execute ----------------------------------------------------
m '(curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)' \
  && deny "Piping a remote download into a shell is blocked. Inspect the script first."

# --- Secret exfiltration via shell ------------------------------------------
# Block shell reads of .env files, but allow public templates (.env.example/.sample/.template).
if m '(cat|less|more|head|tail|bat|nl|strings)[[:space:]]+([^|;&]*[/[:space:]])?\.env([./]|[[:space:]]|$)'; then
  m '\.env\.(example|sample|template|dist)([[:space:]]|$)' \
    || deny "Reading .env via the shell is blocked; secrets must stay out of the transcript."
fi
m '(^|[[:space:]])printenv([[:space:]]|$)'                  && deny "Dumping environment variables (printenv) is blocked."
m '(^|[[:space:]])env([[:space:]]*$|[[:space:]]*\|)'        && deny "Dumping environment variables (env) is blocked."

# --- Publish / production deploy / destructive data -------------------------
m '(npm|pnpm|yarn)[[:space:]]+publish'                      && deny "Package publish is blocked under YOLO mode."
m 'vercel([[:space:]].*)?(--prod([[:space:]]|=|$)|--production)' \
  && deny "Production deploy (vercel --prod) is blocked. Ask the human."
m 'supabase[[:space:]]+db[[:space:]]+reset'                 && deny "supabase db reset destroys data; blocked."
m '(prisma[[:space:]]+migrate[[:space:]]+reset|drizzle-kit[[:space:]]+drop)' \
  && deny "Destructive migration reset is blocked."
m 'DROP[[:space:]]+(TABLE|DATABASE|SCHEMA)([[:space:]]|;|$)' && deny "Destructive SQL (DROP) is blocked."
m '(^|[^[:alnum:]_])TRUNCATE[[:space:]]+(TABLE[[:space:]]+)?[[:alnum:]_]' \
  && deny "Destructive SQL (TRUNCATE) is blocked."

# --- Default: allow ----------------------------------------------------------
# No match -> emit nothing, exit 0. Under bypass mode this lets the command run.
exit 0
