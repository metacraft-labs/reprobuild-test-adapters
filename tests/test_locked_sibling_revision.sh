#!/usr/bin/env bash
# ci/locked-sibling-revision.py returns the revision a repro.lock pins for a
# sibling and refuses every entry that does not name exactly one commit.
#
# Each lock is a real file read by the real script; nothing is mocked. This test
# runs the script with PYTHON (default python3), which must provide tomllib.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$root/ci/locked-sibling-revision.py"
python="${PYTHON:-python3}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rev_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rev_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

lock() { # <deps inline-table list>
	printf 'schema = "reprobuild.solved-graph-lock.v3"\n\n[lock]\ndeps = [%s]\n' "$1" >"$work/repro.lock"
}
accepts() { # <description> <expected>
	local actual
	actual="$("$python" "$tool" "$work/repro.lock" reprobuild)" || {
		echo "FAIL $1: refused" >&2
		exit 1
	}
	[ "$actual" = "$2" ] || {
		echo "FAIL $1: printed '$actual', expected '$2'" >&2
		exit 1
	}
	echo "ok $1"
}
refuses() { # <description> <stderr fragment>
	local actual
	if actual="$("$python" "$tool" "$work/repro.lock" reprobuild 2>"$work/stderr")"; then
		echo "FAIL $1: accepted, printed '$actual'" >&2
		exit 1
	fi
	[ -z "$actual" ] || {
		echo "FAIL $1: printed '$actual' alongside the refusal" >&2
		exit 1
	}
	grep -qF "$2" "$work/stderr" || {
		echo "FAIL $1: stderr lacks '$2': $(cat "$work/stderr")" >&2
		exit 1
	}
	echo "ok $1"
}

lock "{ name = \"own\", self = \"true\", revision = \"$rev_b\" }, { name = \"reprobuild\", revision = \"$rev_a\", integrity = \"git-sha1:$rev_a\" }"
accepts "the sibling's revision is selected from among the entries" "$rev_a"

lock "{ name = \"reprobuild\", revision = \"$rev_a\" }"
accepts "an entry without integrity is accepted" "$rev_a"

lock "{ name = \"reprobuild\", self = \"true\", revision = \"$rev_a\" }"
refuses "the repository's own entry is not a sibling" "found 0"

lock "{ name = \"other\", revision = \"$rev_a\" }"
refuses "an absent sibling is refused" "found 0"

lock "{ name = \"reprobuild\", revision = \"$rev_a\" }, { name = \"reprobuild\", revision = \"$rev_b\" }"
refuses "two entries are ambiguous" "found 2"

lock "{ name = \"reprobuild\", revision = \"agents\" }"
refuses "a branch name is not a commit id" "not a commit id"

lock "{ name = \"reprobuild\", revision = \"${rev_a:0:12}\" }"
refuses "an abbreviated revision is not a commit id" "not a commit id"

lock "{ name = \"reprobuild\", revision = \"$rev_a\", integrity = \"git-sha1:$rev_b\" }"
refuses "integrity naming another commit is a contradiction" "integrity git-sha1:$rev_b"

printf 'not toml = [' >"$work/repro.lock"
refuses "an unparsable lock is refused" "repro.lock"

rm "$work/repro.lock"
refuses "a missing lock is refused" "repro.lock"
