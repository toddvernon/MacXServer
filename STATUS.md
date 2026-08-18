# Status 2026-08-18 (Mac Studio)

## Headline: second real Indigo brought to life as indigo4b. Todd's PSU/
## battery/serial-cable bench work plus a full remote software rescue over
## helios: the indigo4k clone got a new identity (indigo4b, 192.168.7.22),
## a correct clock, and working LG2 graphics. The "won't boot graphical"
## mystery was never hardware: the cloned disk only had Elan's drivers.
## No repo code changed today; everything was on-box, DNS, and user config.
## NOTE: the 07-28 rebrand-to-macSPARCstation queue is STILL front of
## queue and untouched; carried below in full.

## What happened today

All bench + on-box work, no commits in any repo (this STATUS roll is the
only tree change).

**The machine:** second SGI Indigo, R4000 100MHz IP20, 48MB, base LG1/LG2
graphics (gfxinfo: LG2 rev 3, driver family LG1MC, 1024x768/8-bit which
is the hardware max). Boots a ZuluSCSI Blaster clone of indigo4k's disk.
Todd replaced the clock battery, built a serial cable, and reset the
root password (value in Claude memory, not in this public tree).

**Identity:** now indigo4b / 192.168.7.22 (static, next slot after the
fleet's .4-.21 block; DHCP pool is up high, Mac leases .207). /etc/sys_id
+ /etc/hosts edited over helios (backups *.indigo4k.bak on the box), DNS
added on the Pi-hole (dnsmasq on .3), TZ fixed to MST7MDT (clone had a
stray PST8PDT line), clock set, netwr_client chkconfig'd off (ipxlink
noise). Both real Indigos can now coexist (4k=.7, 4b=.22).

**Graphics rescue (the day's meat):** kernel + gfxinfo saw NO graphics
board because inst installs only mach()-tagged files for the machine it
runs on -- the clone had gr2.a (Elan), no lg1.a, no LG1 GL, no lg1mc.so
X DDX. PROM hinv proved the board itself was fine. Fix: ripped Todd's
IRIX 6.5 CD set on the Mac (Foundation 1+2, 6.5.8 Overlays 1-3), served
them from a CD4/ folder on the Zulu SD card (multi-image CD at SCSI ID 4,
`eject /CDROM` advances discs -- swapping done entirely over helios),
staged the eoe/x_eoe products to /usr/dist/{foundation1,overlays1,2,3}
on the box, then inst-reinstalled eoe.sw.gfx + eoe.sw.gltools +
x_eoe.sw.Server with the machine override. THE TRAP (cost two failed
passes): inst -m REPLACES the whole machine description with only what
you pass, comma lists don't parse, CPUARCH isn't a variable. Correct
form: `inst -m CPUBOARD=IP20 -m GFXBOARD=LIGHT -m SUBGR=LG1MC -m
MODE=32bit`, one -m per assignment, and `admin hardware` in the command
file to verify. autoconfig -f, reboot: login screen on the monitor.
Bonus lesson: keyboard presence (not nvram console=d) decides whether
the PROM uses the graphics head.

**Mac side:** machines.json got an Indigo4b entry (clone of Indigo4k,
fresh UUID; app relaunched and the prober adopted it fine). dev-secrets
got the indigo4b helios/telnet keys. Project .claude/settings.json
gained a permissions allowlist (helios CLI, ping/dig/arp/nc, diskutil
list/info/eject, xxd, ipconfig) so fleet probing doesn't prompt.
Everything recorded in memory: reference_indigo4b_lg2_bringup.

## What's working / what's broken

- indigo4b: up, graphical login on the monitor, helios agent live at
  .22:2125, macXserver dashboard line rendering. 6.5 media staged on its
  disk AND on its Zulu SD -- future driver work needs no physical CD.
- The ripped ISOs also sit in Mac /tmp/CD4 -- Todd wants them hosted on
  oldsilicon.com. /tmp DIES ON MAC REBOOT: move them somewhere durable
  first (and cmp after any NAS/SMB copy, that path corrupted before).
- indigo4b agent binary is the same vintage as indigo4k's: predates the
  /proc disk filter + sysmp avenrun fix; GNU grep still absent (search
  verb errors). Same next-tar item as the 4k, now times two.
- Original indigo4k untouched today (stayed off while its clone squatted
  on .7; safe to power on again now).
- Release images: still cut and publish-ready ON THE LAPTOP ONLY; held
  pending the rebrand URLs.

## What's next

**Front of the queue (carried from 07-28, untouched again today -- the
rebrand must settle before publish):**

1. Todd answers the four rebrand sub-decisions: (a) display casing
   (assume macSPARCstation), (b) rename macxserver-images in place
   (recommended: raw-URL redirect keeps v0.9.9 beta binaries alive) vs
   fresh repo, (c) lockstep .macxserver-lock rename or leave, (d)
   bundle id com.toddvernon.macsparcstation.
2. Execute the rename batch: images repo + pinned URL FIRST (unblocks
   --publish), then app identity + strings + config paths + migration.
3. New site: clone MacXServerSite as the base for macsparcstation.com,
   rework around the grander pitch; banner the old site over.
4. ./build-catalog.sh --publish from THE LAPTOP (images gated and
   waiting; tag defaults to v2026.07) once URLs are final.
5. Virgin-box end-to-end acceptance: fresh account, real domain, real
   download, install wizard, boot to ready.

**Indigo follow-ups (small, now for BOTH machines):**

6. Ship the next heliosAgent tar to indigo4k AND indigo4b (/proc filter
   + sysmp avenrun); GNU grep tardist or HELIOS_GREP on both.
7. Indigo4k entry polish (app quit first): transport -> helios, curated
   launcher set (4b already carries the curated 10).
8. Clock panel + user admin live against a real Indigo (builders are
   probe-verified; full pipelines still haven't run against one).
9. Move /tmp/CD4 ISOs somewhere durable; oldsilicon.com hosting page.

**Carried from earlier sessions:** Xcode rebuild + click-through of the
07-28 UX consolidation (wizard domain field, settings panes, seeded
launchers, image-folder mover, Forget Password, slimmed menus); laptop
machines.json fixture reseed (optional); CanonicalDotfiles DISPLAY
decision; UserAdmin live test on 2.6/4.1.4.

## Committed / push state

- X, main: this STATUS roll only. Pushed at /eos.
- cx family + SPARCplug: untouched today, all clean.

## Switching Macs

- indigo4b is a live fleet member now; nothing holds a lock anywhere.
- machines.json / dev-secrets changes are Mac-Studio-local (per-Mac
  config, doesn't sync) -- the laptop's app won't know indigo4b until
  its own machines.json gets an entry or the wizard adds one.
- Memory (reference_indigo4b_lg2_bringup) rides Dropbox -- let it sync.
- Release images still wait on the LAPTOP; rebrand queue is the gate.
