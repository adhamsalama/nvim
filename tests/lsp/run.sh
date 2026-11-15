#!/usr/bin/env bash
# Snapshot the custom LSP code's wiring and behavior against a real JS/TS project, and compare
# against a saved baseline.
#
#   tests/lsp/run.sh <project-dir> <out-dir>            # write the five snapshots to out-dir
#   tests/lsp/run.sh <project-dir> <out-dir> <base-dir> # ...then diff against base-dir, fail on change
#
# Env: LSP_TEST_CASES=<file> (required) the project's targets: which files to open and where to
#      put the cursor; see cases.example.lua. Keep it outside this repo.
#      SNAPSHOT_ONLY=<substring> runs only the behavior cases whose name contains it.
#      NVIM_CONFIG_DIR=<dir> runs the config in <dir> (e.g. a git worktree of another commit)
#      instead of ~/.config/nvim; the rest of ~/.config stays visible to the tools nvim starts.
# The five scripts run in parallel, each in its own Neovim with its own state dir.
# The project is only read (buffers are loaded without swap files and never written). Neovim's
# state dir (shada, logs, swap, the slow-request log) is redirected into out-dir, and the scripts
# drop the session autosave before quitting, so runs leave the real editor state alone.
set -euo pipefail

: "${LSP_TEST_CASES:?set LSP_TEST_CASES to the cases file of the project (see tests/lsp/cases.example.lua)}"
project=${1:?project dir}
out=${2:?out dir}
base=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

xdg_config=${XDG_CONFIG_HOME:-$HOME/.config}
if [[ -n "${NVIM_CONFIG_DIR:-}" ]]; then
  # stdpath("config") is $XDG_CONFIG_HOME/nvim: a config home with nvim -> the given dir and
  # everything else linked from the real one (git, copilot auth, ...)
  cfg=$(cd "$NVIM_CONFIG_DIR" && pwd)
  xdg_config="$out/config-home"
  rm -rf "$xdg_config" && mkdir -p "$xdg_config"
  for f in "${XDG_CONFIG_HOME:-$HOME/.config}"/* "${XDG_CONFIG_HOME:-$HOME/.config}"/.[!.]*; do
    if [[ -e "$f" && "$(basename "$f")" != nvim ]]; then ln -s "$f" "$xdg_config/$(basename "$f")"; fi
  done
  ln -s "$cfg" "$xdg_config/nvim"
fi

run() { # <script> <output> [<script loaded before the config>]
  local start="autocmd VimEnter * ++once lua vim.schedule(function() dofile('$here/$1') end)"
  local pre=()
  if [[ -n "${3:-}" ]]; then pre=(--cmd "lua dofile('$here/$3')"); fi
  local name=${2%.txt}
  local state="$out/state-$name" tmp="$out/tmp-$name"
  rm -rf "$state" "$tmp" && mkdir -p "$state" "$tmp"
  (cd "$project" && XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$state" SNAPSHOT_TMP="$tmp" SNAPSHOT_OUT="$out/$2" \
    perl -e 'alarm 1800; exec @ARGV' nvim --headless ${pre[@]+"${pre[@]}"} --cmd "$start" 2>"$out/$name.log") || {
    echo "FAILED: $1 (see $out/$name.log)" >&2
    tail -20 "$out/$name.log" >&2
    return 1
  }
}

pids=()
run wiring.lua wiring.txt &
pids+=($!)
run behavior.lua behavior.txt &
pids+=($!)
run ui.lua ui.txt &
pids+=($!)
run runtime.lua runtime.txt &
pids+=($!)
run trace.lua trace.txt trace_hook.lua &
pids+=($!)
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
[[ $failed == 0 ]] || exit 1
echo "snapshots written to $out"

if [[ -n "$base" ]]; then
  status=0
  for f in wiring.txt behavior.txt ui.txt runtime.txt trace.txt; do
    if diff -u "$base/$f" "$out/$f"; then echo "same: $f"; else status=1; fi
  done
  exit $status
fi
