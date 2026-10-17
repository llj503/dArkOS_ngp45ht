#!/bin/bash
# In every package: / is root's. The images up to the test builds of 1.1 gave
# it to ark (bootstrap_rootfs-rk3562.sh), so anything running as ark could
# create files there. PPSSPP 1.12.3 (ppsspp-2021) left a /ppsspp_N.ram there
# on each start: it is that emulator's PSP memory, and it was kept on the SD
# card, never deleted. Those go too. Neither is in the merged list, since a
# rollback has no use for them. It never fails the update.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [ "$(stat -c %u:%g:%a /)" != 0:0:755 ]; then
  chown root:root / && chmod 755 / && echo "  /: root's"
fi
for f in /ppsspp_[0-9]*.ram; do
  [ -f "$f" ] && rm -f "$f" && echo "  removed $f"
done
exit 0
