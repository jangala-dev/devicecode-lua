The scripts under this folder when placed in the `/etc/hotplug.d/` (for most scripts) and `/etc/` (for `mwan3.user`) folders will hook into hotplug event and send events over ubus system.

By executing `usb listen {address}` real-time events will be received over `stdout`
