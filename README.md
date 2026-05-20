# SteamOS Deployment for Pterodactyl

QEMU-based SteamOS deployment container and Pterodactyl egg.

Upload your SteamOS image manually to the server root:

```text
/home/container/steamdeck-repair-20250521.10-3.7.7.img.bz2
```
Do not commit the SteamOS image to GitHub.

First boot with RUN_MODE=install. After SteamOS is installed onto /home/container/disks/steamos.qcow2, switch to RUN_MODE=run.

This is highly dependent on /dev/kvm. Without KVM, SteamOS may be unusably slow.
