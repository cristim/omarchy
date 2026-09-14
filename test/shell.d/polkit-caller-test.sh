#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
mock_bin="$test_tmp/bin"
pid_file="$test_tmp/pid"
mkdir -p "$mock_bin"

outer_pid=""
cleanup() {
  [[ -n $outer_pid ]] && pkill -P "$outer_pid" 2>/dev/null
  [[ -n $outer_pid ]] && kill "$outer_pid" 2>/dev/null
  rm -rf "$test_tmp"
}
trap cleanup EXIT

# A stand-in for a waiting pkexec: a process whose argv[0] is pkexec and whose
# arguments name the program, started by a script that waits on it.
cat >"$test_tmp/outer-caller" <<SH
#!/bin/bash
bash -c 'echo \$\$ >"$pid_file"; exec -a pkexec tail -f /dev/null true >/dev/null 2>&1'
:
SH
chmod +x "$test_tmp/outer-caller"

"$test_tmp/outer-caller" &
outer_pid=$!

for _ in $(seq 50); do
  [[ -s $pid_file ]] && break
  sleep 0.1
done
[[ -s $pid_file ]] || fail "stand-in pkexec started"

cat >"$mock_bin/ps" <<SH
#!/bin/bash
cat "$pid_file"
SH
chmod +x "$mock_bin/ps"

export PATH="$mock_bin:$ROOT/bin:$PATH"

# The prompt's message carries the resolved path; pkexec's argv keeps the bare
# name the caller typed.
chain=$(omarchy-polkit-caller /usr/bin/true) || fail "caller helper finds a pkexec started with a bare program name"
[[ $chain == "outer-caller ← "* || $chain == "outer-caller" ]] || fail "caller chain starts with the script that ran pkexec" "$chain"
pass "caller chain starts with the script that ran pkexec"

chain=$(omarchy-polkit-caller true) || fail "caller helper matches the program exactly"
[[ $chain == "outer-caller"* ]] || fail "caller helper matches the program exactly" "$chain"
pass "caller helper matches the program exactly"

if omarchy-polkit-caller /usr/bin/false >/dev/null; then
  fail "caller helper reports nothing for a program no pkexec is running"
fi
pass "caller helper reports nothing for a program no pkexec is running"
