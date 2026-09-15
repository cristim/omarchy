#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export OMARCHY_PROC_PATH="$test_tmp/proc"
export PATH="$ROOT/bin:$PATH"

# fake_process <pid> <ppid> <comm> <euid> <exe or ""> <argv...>
# Every fake process was started by this user, so its real uid is ours.
fake_process() {
  local pid=$1 ppid=$2 comm=$3 euid=$4 exe=$5
  shift 5
  local dir="$OMARCHY_PROC_PATH/$pid"
  mkdir -p "$dir"
  printf '%s\n' "$comm" >"$dir/comm"
  printf '%s (%s) S %s %s %s 0 -1\n' "$pid" "$comm" "$ppid" "$ppid" "$ppid" >"$dir/stat"
  printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$comm" "$UID" "$euid" "$euid" "$euid" >"$dir/status"
  if [[ -n $exe ]]; then
    ln -s "$exe" "$dir/exe"
  fi
  printf '%s\0' "$@" >"$dir/cmdline"
}

# expect_chain <program> <chain> <description>
expect_chain() {
  local actual
  actual=$(timeout 5 omarchy-polkit-caller "$1") || fail "$3" "no chain for $1"
  [[ $actual == "$2" ]] || fail "$3" "expected: $2"$'\n'"actual:   $actual"
  pass "$3"
}

# expect_no_match <program> <description>
expect_no_match() {
  if timeout 5 omarchy-polkit-caller "$1" >/dev/null; then
    fail "$2"
  fi
  pass "$2"
}

# Named init, not systemd, so only the pid check can stop the walk there.
fake_process 1 0 init 0 "" /sbin/init
fake_process 900 1 systemd "$UID" /usr/lib/systemd/systemd /usr/lib/systemd/systemd --user
fake_process 1000 900 foot "$UID" /usr/bin/foot foot
fake_process 1001 1000 bash "$UID" /usr/bin/bash -bash
fake_process 1002 1001 omarchy-update "$UID" /usr/bin/bash /bin/bash /usr/share/omarchy/bin/omarchy-update
fake_process 1003 1002 pkexec 0 "" pkexec --user root --disable-internal-agent /usr/bin/pacman -Syu --noconfirm

expect_chain /usr/bin/pacman "omarchy-update ← bash ← foot" "caller names the processes above pkexec, stopping at systemd"
expect_no_match /usr/bin/root "caller never takes a pkexec option value for the program"
expect_no_match /usr/bin/-Syu "caller only matches the program, not its arguments"

fake_process 1010 1000 pkexec 0 "" pkexec -u root /usr/bin/id
expect_chain /usr/bin/id "foot" "caller skips -u and its value"

# A process named pkexec that isn't running as root, and a setuid program
# another account started through a symlink named pkexec.
fake_process 2000 1000 pkexec "$UID" "" pkexec /usr/bin/pacman -Syu
fake_process 2001 1000 pkexec 0 "" pkexec -u root /usr/bin/pacman -Syu
printf 'Name:\tpkexec\nUid:\t%s\t0\t0\t0\n' $((UID + 1)) >"$OMARCHY_PROC_PATH/2001/status"
expect_chain /usr/bin/pacman "omarchy-update ← bash ← foot" "caller only counts a pkexec running as root for this user"

fake_process 1100 1000 bash "$UID" /usr/bin/bash bash -c "pkexec --keep-cwd true"
fake_process 1101 1100 pkexec 0 "" pkexec --keep-cwd true
expect_chain /usr/bin/true "bash ← foot" "caller matches the resolved path against the bare name pkexec was given"

fake_process 1200 1000 pkexec 0 "" pkexec true
expect_no_match /usr/bin/true "caller finds no match when two pkexecs run the same program"

# A replaced executable, a parent whose executable can't be read, and a comm
# with ") " in it.
fake_process 3001 900 foot "$UID" /usr/bin/foot foot
fake_process 3002 3001 "odd) name" "$UID" /usr/bin/odd odd
fake_process 3003 3002 sudo 0 "" sudo /usr/share/omarchy/bin/omarchy-update
fake_process 3004 3003 omarchy-update "$UID" "/usr/bin/bash (deleted)" /bin/bash /usr/share/omarchy/bin/omarchy-update
fake_process 3005 3004 pkexec 0 "" pkexec /usr/bin/journalctl
expect_chain /usr/bin/journalctl "omarchy-update ← sudo ← odd ← foot" "caller names replaced and unreadable executables and parses odd comms"

fake_process 4001 900 p1 "$UID" /usr/bin/p1 p1
for level in 2 3 4 5 6 7; do
  fake_process $((4000 + level)) $((3999 + level)) "p$level" "$UID" "/usr/bin/p$level" "p$level"
done
fake_process 4008 4007 pkexec 0 "" pkexec /usr/bin/lsblk
expect_chain /usr/bin/lsblk "p7 ← p6 ← p5 ← p4 ← p3" "caller walks at most five parents"

fake_process 5000 900 pkexec 0 "" pkexec /usr/bin/uptime
expect_chain /usr/bin/uptime "" "caller names nobody for a pkexec started by systemd"

fake_process 7100 1 pkexec 0 "" pkexec /usr/bin/whoami
expect_chain /usr/bin/whoami "" "caller names nobody for a pkexec whose parent is pid 1"

long=$(printf 'x%.0s' {1..60})
fake_process 6001 900 sh "$UID" /usr/bin/bash /bin/sh $'/tmp/evil\n\xe2\x80\xaename'
fake_process 6002 6001 sh "$UID" /usr/bin/bash /bin/sh $'/tmp/evil\n\xe2\x80\xaename'
fake_process 6003 6002 sh "$UID" /usr/bin/bash /bin/sh "/tmp/$long"
fake_process 6004 6003 pkexec 0 "" pkexec /usr/bin/systemctl restart sshd
expect_chain /usr/bin/systemctl "${long:0:40}… ← evilname" "caller strips control and bidi characters, cuts long names and collapses repeats"

fake_process 7200 900 sh "$UID" /usr/bin/bash /bin/sh $'/opt/p\xe2\x80\x8fq\xe2\x80\xaa\xe2\x80\xadr\xe2\x81\xa0\xe2\x81\xa9\x7fs'
fake_process 7201 7200 pkexec 0 "" pkexec /usr/bin/loginctl
expect_chain /usr/bin/loginctl "pqrs" "caller strips characters from each hidden range"

forty=$(printf 'z%.0s' {1..40})
forty_one=$(printf 'y%.0s' {1..41})
fake_process 7300 900 sh "$UID" /usr/bin/bash /bin/sh "/opt/$forty"
fake_process 7301 7300 sh "$UID" /usr/bin/bash /bin/sh "/opt/$forty_one"
fake_process 7302 7301 pkexec 0 "" pkexec /usr/bin/timedatectl
expect_chain /usr/bin/timedatectl "${forty_one:0:40}… ← $forty" "caller keeps a 40-character name and cuts a 41-character one"

# pkexec's --disable-internal-agent is skipped, a Python script is named after
# the script, and a parent whose name comes out empty is left out.
fake_process 7400 1000 ghost "$UID" / ghost
fake_process 7401 7400 python3 "$UID" /usr/bin/python3.13 /usr/bin/python3 /opt/tool.py
fake_process 7402 7401 pkexec 0 "" pkexec --disable-internal-agent --keep-cwd /usr/bin/busctl
expect_chain /usr/bin/busctl "tool.py ← foot" "caller names Python scripts and leaves out empty names"

# Whatever the caller's locale: every hidden kind goes, other multibyte text
# stays, and the cut counts characters.
cjk=$(printf '\xe6\x97\xa5%.0s' {1..45})
fake_process 7001 900 sh "$UID" /usr/bin/bash /bin/sh $'/opt/a\xd8\x9c\xe6\x97\xa5\xe2\x80\x8b\xf0\x9f\x98\x80\xe2\x81\xa6\xc3\xa9\xef\xbb\xbf\xc2\x85\xe2\x80\xa8b'
fake_process 7002 7001 sh "$UID" /usr/bin/bash /bin/sh "/opt/$cjk"
fake_process 7003 7002 pkexec 0 "" pkexec /usr/bin/hostnamectl
LC_ALL=C expect_chain /usr/bin/hostnamectl "$(printf '\xe6\x97\xa5%.0s' {1..40})… ← a"$'\xe6\x97\xa5\xf0\x9f\x98\x80\xc3\xa9'"b" \
  "caller keeps other multibyte text and cuts by characters in any locale"

# A process can make its arguments as long as the kernel allows; the lookup must
# still finish quickly.
huge=$(printf 'h%.0s' {1..131000})
fake_process 8000 900 python3 "$UID" /usr/bin/python3.13 python3 "/opt/$huge"
fake_process 8001 8000 python3 "$UID" /usr/bin/python3.13 python3 "/opt/$huge"
fake_process 8002 8001 pkexec 0 "" pkexec /usr/bin/dmesg
expect_chain /usr/bin/dmesg "${huge:0:40}…" "caller handles huge process names quickly"

padding=()
for _ in {1..20}; do
  padding+=(--keep-cwd)
done
fake_process 8100 900 pkexec 0 "" pkexec "${padding[@]}" /usr/bin/ip
expect_no_match /usr/bin/ip "caller stops reading pkexec options after 16"

expect_no_match /usr/bin/missing "caller finds no match when no pkexec runs the program"
