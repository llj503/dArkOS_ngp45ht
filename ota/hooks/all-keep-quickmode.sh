#!/bin/bash
# In every package, first: keep Quick Mode on. "Enable Quick Mode" copies
# pause.sh.qm and finish.sh.qm over /usr/local/bin/pause.sh and finish.sh, and
# swaps its entry in Options -> Advanced for "Disable Quick Mode". None of it is
# under etc/, home/, root/ or var/lib/, so the client lays the update's files
# over it, and Quick Mode would be left half on. While it is on (quickmode.sh is
# there), this does it again with the update's versions.
#
# What it changes is listed in /var/lib/darkos-ota/merged, from where the
# client puts it back on a rollback. It never fails the update.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
B=/usr/local/bin
A=/opt/system/Advanced
MERGED=/var/lib/darkos-ota/merged

[ -e $B/quickmode.sh ] || exit 0
mkdir -p "$(dirname $MERGED)"

# put SRC DST: DST becomes a copy of SRC. It keeps its owner and mode; a new
# one gets its directory's owner and 755, as "Enable Quick Mode" leaves it.
put() {
  [ -f "$1" ] || return 0
  cmp -s "$1" "$2" && return 0
  local tmp="$(dirname "$2")/.ota-tmp.$(basename "$2")"
  echo "$2" >> $MERGED
  cp "$1" "$tmp" || return 0
  if [ -e "$2" ]; then
    chown --reference="$2" "$tmp"; chmod --reference="$2" "$tmp"
  else
    chown --reference="$(dirname "$2")" "$tmp"; chmod 755 "$tmp"
  fi
  mv -f "$tmp" "$2" && echo "  quick mode: $2"
}

put $B/pause.sh.qm $B/pause.sh
put $B/finish.sh.qm $B/finish.sh
if [ -d $A ]; then
  if [ -e "$A/Enable Quick Mode.sh" ]; then
    echo "$A/Enable Quick Mode.sh" >> $MERGED
    rm -f "$A/Enable Quick Mode.sh" && echo "  quick mode: $A/Enable Quick Mode.sh removed"
  fi
  put "$B/Disable Quick Mode.sh" "$A/Disable Quick Mode.sh"
fi
exit 0
