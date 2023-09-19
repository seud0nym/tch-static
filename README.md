# tch-static

Packages containing statically linked arm binaries, specifically for deployment on Technicolor Gateway routers.

## Configuring opkg

The `/etc/opkg.conf` file must contain the architecture for your device. e.g. for a 32 bit Technicolor device, it will look something like this:
```
dest root /
dest ram /tmp
lists_dir ext /var/opkg-lists
option overlay_root /overlay
arch all 1
arch noarch 1
arch arm_cortex-a9 10
arch arm_cortex-a9_neon 20
arch brcm63xx-tch 30
arch bcm53xx 40
```

For a 64-bit device such as the Telstra Smart Modem Gen 3, it will look something like this:
```
dest root /
dest ram /tmp
lists_dir ext /var/opkg-lists
option overlay_root /overlay
option check_signature
dest lcm_native /opt/
arch all 1
arch noarch 1
arch arm_cortex-a53 10
arch aarch64_cortex-a53 20
```

The following line also needs to be added to `/etc/opkg/customfeeds.conf`:
```
src/gz tch_static https://raw.githubusercontent.com/seud0nym/tch-static/master/repository/arm_cortex-a9/packages
```

## Building

The binaries were built using the `build.sh` script on Debian v11.6 (bullseye) running on a Marvell Feroceon 88FR131 (armv5tel) processor system. The script checks for and installs required dependencies.

The individual OpenWrt opkg .ipk files are built using an adapted version of the `make-ipk.sh` from https://bitsum.com/creating_ipk_packages.htm.
