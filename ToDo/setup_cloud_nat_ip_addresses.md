# list libvirt networks (make sure "default" is active)
virsh net-list --all


# dump the active XML for the default network
sudo virsh net-dumpxml default


# View the auto-generated dnsmasq config for the default network
sudo cat /var/lib/libvirt/dnsmasq/default.conf

#  Edit the Default Network XML (virbr0)
sudo virsh net-edit default

# Restart the network to apply the change
sudo virsh net-destroy default
sudo virsh net-start default

# ✅ **What “GNS3 router facing the host” actually means**

It simply means:

> The **router inside your GNS3 topology** that connects directly to your **virbr0 cloud** (the interface that links VMs to Ubuntu).

So:

    Ubuntu Host
     └── virbr0: 192.168.100.1/26
            |
            |  (GNS3 Cloud: virbr0)
            |
       Router in GNS3
            |
       Other internal networks (VLSM)

The router interface *connected to virbr0* must be assigned:

    192.168.100.2/26

This gives you:

*   Host IP: **192.168.100.1/26**
*   Router IP: **192.168.100.2/26**
*   Both on the same L2 segment
*   Router becomes the gateway for all inside networks

***

# 🟦 **Step 1 — Connect the Router to virbr0 in GNS3**

In GNS3:

1.  Drag a **Cloud** node onto the workspace
2.  Edit the Cloud → **NIO Ethernet** → choose:  
    ✔ **virbr0**
3.  Drag a **router** (Cisco, VyOS, FRR, etc.)
4.  Connect the router’s interface (e.g. `eth0` or `GigabitEthernet0/0`) to the cloud.

That creates the link.

***

# 🟩 **Step 2 — Assign 192.168.100.2/26 on the Router Interface**

Below are instructions for different router types.

***

# 🔵 **If your router is VyOS**

Enter configuration mode:

```bash
configure
```

Set the address:

```bash
set interfaces ethernet eth0 address 192.168.100.2/26
```

Commit + save:

```bash
commit
save
exit
```

***

# 🔵 **If your router is Cisco IOS (IOL / Dynamips)**

Enter interface config:

```plaintext
configure terminal
interface GigabitEthernet0/0
 ip address 192.168.100.2 255.255.255.192
 no shutdown
exit
```

Save:

```plaintext
write memory
```

***

# 🔵 **If your router is FRR (Linux + FRRouting)**

Edit interface config in FRR shell:

```bash
vtysh
```

Then:

```plaintext
configure terminal
interface eth0
 ip address 192.168.100.2/26
exit
write
```

***

# 🔵 **If your router is a Linux VM acting as a router**

Use:

```bash
sudo ip addr add 192.168.100.2/26 dev eth0
sudo ip link set eth0 up
```

***

# 🟧 **Step 3 — Set the Router as Default Gateway for All Internal Subnets**

Your internal subnets (behind the router) use:

    GW = 192.168.100.2

Example for a VM inside `192.168.100.64/26`:

    IP: 192.168.100.70
    Mask: 255.255.255.192
    Gateway: 192.168.100.2
    DNS: <whatever>

***

# 🟥 **Step 4 — Ubuntu Routes ALL VLSM subnets to the Router**

These are the routes in netplan I gave earlier:

```yaml
routes:
  - to: 192.168.100.64/26
    via: 192.168.100.2
  - to: 192.168.100.128/26
    via: 192.168.100.2
  - to: 192.168.100.192/26
    via: 192.168.100.2
```

This tells Ubuntu:

> “Any traffic to the VLSM subnets should go to route-IP 192.168.100.2 (the GNS3 router).”

Then NAT works across **all** of 192.168.100.0/24.

***

# 🎉 **Once 192.168.100.2 is set, EVERYTHING works properly**

You now have:

*   🔵 Correct interface pairing:  
    `virbr0 ↔ router eth0`

*   🟣 Correct gateway for all internal networks:  
    `192.168.100.2`

*   🟢 Correct static routes on Ubuntu

*   🟡 Ubuntu NAT translating the entire `/24`

This is exactly how enterprise networks do VLSM + NAT summary.

***
