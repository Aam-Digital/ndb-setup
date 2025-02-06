#!/bin/bash

## update os

apt update && apt upgrade -y && apt autoremove && apt autoclean

## create non-root (sudo) user

adduser --disabled-password --gecos "" aam
usermod -aG sudo aam

## disable sudo password for non-root user (todo: more specific rules)
echo "aam ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

## copy ssh keys to non-root user
mkdir /home/aam/.ssh
cp .ssh/authorized_keys /home/aam/.ssh/authorized_keys
chown -R aam:aam /home/aam/.ssh
chmod 700 /home/aam/.ssh
chmod 644 /home/aam/.ssh/authorized_keys

## disable root login
sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin no/g' /etc/ssh/sshd_config

## install fail2ban and ufw
apt install -y python3-systemd fail2ban ufw
ufw --force enable
ufw allow 22
ufw allow 80
ufw allow 443
ufw reload

cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

sed -i 's/# \[sshd\]/# \[_sshd\]/g' /etc/fail2ban/jail.local

sed -i '/\[sshd\]/,/^\s*$/{
/\[sshd\]/!d
s/\[sshd\]/[sshd]\nenabled = true\nfilter = sshd\nmaxretry = 6/
}' /etc/fail2ban/jail.local

sed -i 's/logpath = %(sshd_log)s/logpath = \/var\/log\/auth.log/g' /etc/fail2ban/jail.local
sed -i 's/backend = %(sshd_backend)s/backend = systemd/g' /etc/fail2ban/jail.local

systemctl restart fail2ban
systemctl status fail2ban

systemctl restart ssh.service

## install docker
apt install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

### Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update

apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker aam

mkdir /var/docker

chown -R aam:aam /var/docker

## install utils
apt install -y git jq

## run as aam user
git clone git@github.com:Aam-Digital/ndb-setup.git /var/docker/ndb-setup
