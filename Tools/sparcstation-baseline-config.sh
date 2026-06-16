#!/bin/sh
#
# macXserver SPARCstation plugin -- generic slirp baseline config.
#
# Run this script as root inside a Solaris 2.6 SPARC QEMU guest to
# turn its persistent network/terminal config into the
# "works on any Mac, no setup, no LAN dependency" baseline used by
# the macXserver SPARCstation plugin. Reboot after running, then
# `savevm` to snapshot.
#
# Idempotent: safe to re-run; backs up every file it touches to
# /var/tmp/macxserver-baseline-backup/ before overwriting.
#
# Assumes the guest is being launched with QEMU `-nic user,...`
# (slirp NAT, guest at 10.0.2.15, gateway at 10.0.2.2). For
# vmnet-shared mode this script is the wrong tool.
#
# Authored 2026-06-16 alongside SPARCSTATION_PLUGIN.md.

echo "=== macXserver SPARCstation baseline config ==="
echo

# Root check (Solaris 2.6's id has no -u; parse the long form)
case "`id`" in
    uid=0\(*) ;;
    *) echo "ERROR: must run as root."; exit 1 ;;
esac
echo "root check: OK"

BACKUP=/var/tmp/macxserver-baseline-backup
mkdir -p "$BACKUP"
echo "backups -> $BACKUP"

HNAME=`cat /etc/nodename 2>/dev/null`
if [ -z "$HNAME" ]; then
    HNAME=sparcstation
fi
echo "hostname:  $HNAME"
echo

# 1. /etc/hostname.le0 -> 10.0.2.15
echo "[1] /etc/hostname.le0 ..."
cp /etc/hostname.le0 "$BACKUP/hostname.le0" 2>/dev/null
echo "10.0.2.15" > /etc/hostname.le0
echo "    now: `cat /etc/hostname.le0`"
echo "    OK"

# 2. /etc/hosts
echo "[2] /etc/hosts ..."
cp /etc/hosts "$BACKUP/hosts" 2>/dev/null
rm -f /etc/hosts
echo "#"                                            >  /etc/hosts
echo "# Internet host table"                        >> /etc/hosts
echo "#"                                            >> /etc/hosts
echo "127.0.0.1       localhost"                    >> /etc/hosts
echo "10.0.2.15       $HNAME $HNAME.local loghost"  >> /etc/hosts
echo "    OK"

# 3. /etc/inet/netmasks
echo "[3] /etc/inet/netmasks ..."
cp /etc/inet/netmasks "$BACKUP/netmasks" 2>/dev/null
if grep '^10\.0\.0\.0' /etc/inet/netmasks > /dev/null 2>&1; then
    echo "    10.0.0.0 entry already present"
else
    echo "10.0.0.0        255.255.255.0" >> /etc/inet/netmasks
    echo "    added 10.0.0.0 255.255.255.0"
fi
echo "    OK"

# 4. /etc/defaultrouter
echo "[4] /etc/defaultrouter ..."
cp /etc/defaultrouter "$BACKUP/defaultrouter" 2>/dev/null
echo "10.0.2.2" > /etc/defaultrouter
echo "    now: `cat /etc/defaultrouter`"
echo "    OK"

# 5. Belt-and-suspenders late-boot default route.
# inetinit's /etc/defaultrouter handling races against interface
# bring-up in some QEMU/Solaris combos; S99defaultroute runs after
# everything else has settled and adds the route then. Harmless if
# inetinit already succeeded (kernel rejects duplicate).
echo "[5] /etc/init.d/defaultroute + S99 link ..."
rm -f /etc/init.d/defaultroute
echo '#!/bin/sh'                                                  >  /etc/init.d/defaultroute
echo 'case "$1" in'                                               >> /etc/init.d/defaultroute
echo "'start')"                                                   >> /etc/init.d/defaultroute
echo '    /usr/sbin/route add default 10.0.2.2 > /dev/null 2>&1'  >> /etc/init.d/defaultroute
echo '    ;;'                                                     >> /etc/init.d/defaultroute
echo 'esac'                                                       >> /etc/init.d/defaultroute
echo 'exit 0'                                                     >> /etc/init.d/defaultroute
chmod +x /etc/init.d/defaultroute
if [ -h /etc/rc3.d/S99defaultroute ] || [ -f /etc/rc3.d/S99defaultroute ]; then
    echo "    rc3.d/S99defaultroute already exists"
else
    ln -s /etc/init.d/defaultroute /etc/rc3.d/S99defaultroute
    echo "    symlinked rc3.d/S99defaultroute"
fi
echo "    OK"

# 6. /etc/resolv.conf -> public DNS.
# Public Google/Cloudflare resolvers; works on any network with
# outbound Internet. Plugin-install UX may want to ask the user for
# their preferred resolver and write a different value here.
echo "[6] /etc/resolv.conf ..."
cp /etc/resolv.conf "$BACKUP/resolv.conf" 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" >  /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "    OK"

# 7. /etc/nsswitch.conf hosts: line uses dns
echo "[7] /etc/nsswitch.conf hosts: ..."
cp /etc/nsswitch.conf "$BACKUP/nsswitch.conf" 2>/dev/null
if grep '^hosts:.*dns' /etc/nsswitch.conf > /dev/null 2>&1; then
    echo "    hosts: already uses dns"
else
    sed -e 's/^hosts:.*$/hosts: files dns/' /etc/nsswitch.conf > /tmp/nsswitch.$$
    mv /tmp/nsswitch.$$ /etc/nsswitch.conf
    echo "    rewrote hosts:"
fi
echo "    now: `grep '^hosts:' /etc/nsswitch.conf`"
echo "    OK"

# 8. /etc/profile -> stty erase ^H.
# xterm by default sends ^H for the BackSpace keysym; align stty so
# the Mac Delete key erases instead of echoing ^H.
echo "[8] /etc/profile (stty erase ^H) ..."
cp /etc/profile "$BACKUP/profile" 2>/dev/null
if grep 'stty erase' /etc/profile > /dev/null 2>&1; then
    echo "    stty erase already present"
else
    echo ""                                                    >> /etc/profile
    echo "# Match xterm BackSpace keysym (sends ^H default)"   >> /etc/profile
    echo "stty erase ^H 2>/dev/null"                           >> /etc/profile
    echo "    added stty erase ^H"
fi
echo "    OK"

echo
echo "=== ALL DONE ==="
echo
echo "backups in $BACKUP (one per file)"
echo
echo "now: init 6"
echo
