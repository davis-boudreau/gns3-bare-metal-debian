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