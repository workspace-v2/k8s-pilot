#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# != 2 || ! "$1" =~ ^[0-9.]+$ || ! "$2" =~ ^[0-9.]+$ ]]; then
  echo "Usage: $0 WORKER_A_PRIVATE_IP WORKER_B_PRIVATE_IP" >&2
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get -qq -o Acquire::Retries=4 update
apt-get -qq -o DPkg::Lock::Timeout=180 install -y nfs-kernel-server
install -d -m 0755 /srv/k8s-pilot-share /etc/exports.d /etc/nfs.conf.d
install -d -m 0775 -o 1000 -g 1000 /srv/k8s-pilot-share/uploads
printf '%s\n' '[nfsd]' 'vers3=n' 'vers4=y' 'udp=n' > /etc/nfs.conf.d/k8s-pilot.conf
printf '/srv/k8s-pilot-share %s(rw,sync,root_squash,fsid=0,crossmnt,no_subtree_check) %s(rw,sync,root_squash,fsid=0,crossmnt,no_subtree_check)\n' \
  "$1" "$2" > /etc/exports.d/k8s-pilot.exports
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
exportfs -ra
