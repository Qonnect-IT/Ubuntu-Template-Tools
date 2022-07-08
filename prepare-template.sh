#!/bin/bash

if [ `id -u` -ne 0 ]; then
	echo This script requires root, please run it with sudo
	exit 1
fi

#Update APT repositories
apt update && NEEDRESTART_SUSPEND=1 apt upgrade -y

#Install OpenVM Tools
apt install open-vm-tools

#Stop RSyslog
service rsyslog stop

#Clear audit logs
if [ -f /var/log/wtmp ]; then
    truncate -s0 /var/log/wtmp
fi
if [ -f /var/log/lastlog ]; then
    truncate -s0 /var/log/lastlog
fi
if [ -f /var/log/audit/audit.log ]; then
    truncate -s0 /var/log/audit/audit.log
fi

#Remove persistent udev rules
if [ -f /etc/udev/rules.d/70-persistent-net.rules ]; then
    rm /etc/udev/rules.d/70-persistent-net.rules
fi

#Cleanup /tmp directories
rm -rf /tmp/*
rm -rf /var/tmp/*

#Cleanup current ssh keys
rm -f /etc/ssh/ssh_host_*

#Regenerate ssh keys on reboot if neccessary
cat << 'EOL' | sudo tee /etc/rc.local
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "" on success or any other
# value on error.
#
test -f /etc/ssh/ssh_host_dsa_key || dpkg-reconfigure openssh-server
exit 0
EOL

#Make sure the script is executable
chmod +x /etc/rc.local

#Generate MOTD
cat << 'EOL' | tee /etc/motd
\033[1;31m###################################### \033[0mWARNING!!!\033[1;31m ###############################################
\033[0m          This template is created and maintained by the prepare-template.sh script.
                 Please run ./prepare-template.sh to perform updates!!
\033[1;31m#################################################################################################
\033[0m
EOL

#Prevent cloudconfig from preserving the original hostname
sed -i 's/preserve_hostname: false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
truncate -s0 /etc/hostname
hostnamectl set-hostname localhost

#Cleanup DHCP Leases with dhclient
dhclient -r

#Cleanup dhcp leases
rm -rf /var/lib/dhcp/dhclient.leases

#cleanup apt
apt clean

# set dhcp to use mac - this is a little bit of a hack but I need this to be placed under the active nic settings
# also look in /etc/netplan for other config files
sed -i 's/optional: true/dhcp-identifier: mac/g' /etc/netplan/50-cloud-init.yaml

# cleans out all of the cloud-init cache / logs - this is mainly cleaning out networking info
cloud-init clean --logs

#Download a copy of this script to the local server in order to make updating this template easy
wget https://raw.githubusercontent.com/Qonnect-IT/Ubuntu-Template-Tools/master/prepare-template.sh

chmod +x prepare-template.sh

#cleanup shell history
cat /dev/null > ~/.bash_history && history -c
history -w

#shutdown
shutdown -h now
