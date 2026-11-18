#!/bin/sh
# SPDX-License-Identifier: MIT
# gcc -wrapper hook used by capture-pack.py: records the argument list of cc1, cc1plus,
# as and collect2 (response files expanded) and runs the tool under strace so the
# capture knows every file it read. FWB_DIR and FWB_TAG come from the caller.
prog=$(basename "$1")
case "$prog" in cc1|cc1plus|as|collect2) ;; *) exec "$@";; esac
out="$FWB_DIR/$FWB_TAG.$prog"
: > "$out.args"
first=1
for a in "$@"; do
  if [ "$first" = 1 ]; then first=0; continue; fi
  case "$a" in
    @*) python3 -c 'import shlex,sys; [print(x) for x in shlex.split(open(sys.argv[1]).read())]' "${a#@}" >> "$out.args";;
    *) printf '%s\n' "$a" >> "$out.args";;
  esac
done
pwd > "$out.cwd"
exec strace -f -qq -e trace=openat,open -e signal=none -o "$out.strace" "$@"
