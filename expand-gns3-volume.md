That error is happening because **`/` (root filesystem) is full**, and your **`/home/gns3/...` lives on `/`** right now:

* `df` shows: `/dev/mapper/ubuntu--vg-ubuntu--lv  98G  94G  0  100%  /`
* So even though the *physical disk* is 512GB, your **root logical volume is only ~98GB** (classic LVM default install).

## 1) Confirm where the space is (2 minutes)

Run these and paste back if anything looks odd:

```bash
df -hT /
df -hT /home
lsblk -f
sudo vgs
sudo lvs -a
```

### Find what filled `/` (usually Docker + VM images + logs)

```bash
sudo du -xhd1 / | sort -h
sudo du -xhd1 /var | sort -h
sudo du -xhd1 /var/lib | sort -h
sudo du -xhd1 /home | sort -h
```

If you see `/var/lib/docker` huge, that’s a big smoking gun.

---

## 2) Quick emergency relief (safe-ish) so GNS3 can create files

These are generally safe and reversible:

```bash
sudo apt-get clean
sudo journalctl --vacuum-time=7d
sudo rm -rf /tmp/* /var/tmp/*
```

**Docker cleanup (be careful):**

* Safer first: remove *unused* data (won’t delete images currently in use by running containers)

```bash
docker system df
docker system prune
```

* More aggressive (removes unused images too):

```bash
docker system prune -a
```

If this is a fresh build host, `-a` is often fine; if you rely on cached images, don’t.

---

## 3) The real fix: use the rest of the 512GB

You have two good options. Pick **A** if you just want the system bigger. Pick **B** if you want a clean “data volume” for GNS3/Docker.

---

# Option A (recommended): Expand the root LV to use free space in the VG

### Step A1 — Check if your VG already has free space

```bash
sudo vgs
```

If `VFree` is **> 0**, you can extend root immediately:

```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo df -hT /
```

Now grow the filesystem (depends on FS type):

Check filesystem type:

```bash
df -T /
```

* If **ext4**:

```bash
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

* If **xfs**:

```bash
sudo xfs_growfs /
```

---

### Step A2 — If `VFree` is 0 but the disk is larger (common), grow the partition + PV first

Most Ubuntu 24.04 LVM installs have the PV on something like `/dev/nvme0n1p3` or `/dev/sda3`.

1. Identify the PV device:

```bash
sudo pvs
lsblk
```

2. Grow the LVM partition to fill the disk (example uses partition 3):

```bash
sudo apt-get update
sudo apt-get install -y cloud-guest-utils
sudo growpart /dev/nvme0n1 3    # OR /dev/sda 3 depending on your disk
```

3. Resize the physical volume:

```bash
sudo pvresize /dev/nvme0n1p3    # OR /dev/sda3
```

4. Now extend LV + filesystem (same as A1):

```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv

# ext4:
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv

# xfs:
sudo xfs_growfs /
```

That will make `/` big enough that `/home/gns3/...` won’t choke.

---

# Option B: Create a dedicated “data” LV for GNS3 (and optionally Docker)

This is the clean “server” approach: keep OS modest, put labs/images/projects on a big volume.

### Step B1 — Create and mount a data LV (example: 350G)

```bash
sudo lvcreate -L 350G -n data ubuntu-vg
sudo mkfs.ext4 /dev/ubuntu-vg/data
sudo mkdir -p /data
echo '/dev/ubuntu-vg/data /data ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo mount -a
df -hT /data
```

### Step B2 — Move GNS3 project storage to /data

```bash
sudo systemctl stop gns3server

sudo mkdir -p /data/GNS3
sudo rsync -aHAX --info=progress2 /home/gns3/GNS3/ /data/GNS3/

sudo mv /home/gns3/GNS3 /home/gns3/GNS3.bak.$(date +%F)
sudo ln -s /data/GNS3 /home/gns3/GNS3
sudo chown -hR gns3:gns3 /home/gns3/GNS3 /data/GNS3

sudo systemctl start gns3server
```

After you confirm it works, you can delete the backup directory to reclaim space.

### Optional: move Docker’s data root to /data (huge win on lab hosts)

Docker defaults to `/var/lib/docker` on `/` and can eat the disk quickly. You can relocate it to `/data/docker` via `/etc/docker/daemon.json`.

---

## 4) Your script isn’t the cause, but you *can* harden it

Your install script is fine; it just assumes storage is available on `/`. Once you expand/move storage, the error goes away.

If you want, add a **pre-flight storage gate** near the top:

```bash
# Require at least 20G free on /
FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "${FREE_GB}" -lt 20 ]; then
  die "Root filesystem has only ${FREE_GB}G free. Expand LVM or move GNS3 storage before installing."
fi
```

---

## If you tell me one thing, I can give you the exact commands

Paste the output of:

```bash
lsblk -f
sudo vgs
sudo pvs
df -hT / /home
```

…and I’ll tell you **exactly** whether you’re in Option A1, A2, or B, and which device name (`/dev/nvme0n1p3` vs `/dev/sda3`) to use.
