#!/usr/bin/env bash
##
## Author: Tyler Smith <tyler@ob1.io>
##
## Description:
##   Install OpenBazaar and ob-relay. The goal is to install ob-relay as
##   quickly as possible so we can use it to communicate the installation
##   status back to the end user. Only do the bare minimum first.
##

set -eux
set -o pipefail

##
## The docker ubuntu14.04 image needs these to get on the same level as the
## DigitalOcean iamge
##

if [ -f /.dockerenv ]; then
  apt-get update
  apt-get -y upgrade iptables
  apt-get install -y openssl ufw apt-transport-https software-properties-common python-software-properties python-setuptools
  dpkg-divert --local --rename --add /sbin/initctl
  rm /sbin/initctl
  ln -s /bin/true /sbin/initctl
fi

##
## Helper functions
##

# Set state writes a string to a file that ob-relay can use to determine progress
mkdir -p /home/openbazaar/.deploy
function setState {
  echo -n "$1" > /home/openbazaar/.deploy/state
}

# Set the ownership of the given directory to openbazaar:openbazaar
function _chown {
  chown -R openbazaar:openbazaar "$1"
}

# Create a directory owned by openbazaar:openbazaar
function _mkdir {
  mkdir "$1"
  chown -R openbazaar:openbazaar "$1"
}

##
## Start ob-relay installation
##

setState INSTALLING_OPENBAZAAR_RELAY

# Create openbazaar user and group
groupadd -f openbazaar
useradd --shell /bin/bash --create-home --home /home/openbazaar -g openbazaar --password "$(openssl passwd -salt a -1 '{{vpsPassword}}')" openbazaar

# Create update scripts
cat > /usr/local/bin/checkout_latest_git_tag <<-EOF
#!/bin/sh
set -e
cd \$1
git fetch origin
tag=\$(git tag | grep -P "^v\d+\.\d+\.\d+$" | sort -V | tail -1)
git checkout --force \$tag
EOF

cat > /usr/local/bin/install_latest_openbazaard <<-EOF
#!/bin/sh
set -e
/usr/local/bin/checkout_latest_git_tag /home/openbazaar/ob-server
/home/openbazaar/venv/bin/pip install -r /home/openbazaar/ob-server/requirements.txt
EOF

cat > /usr/local/bin/install_latest_ob_relay <<-EOF
#!/bin/sh
set -e
/usr/local/bin/checkout_latest_git_tag /home/openbazaar/ob-relay
cd /home/openbazaar/ob-relay && npm install
EOF

_chown /usr/local/bin/checkout_latest_git_tag
_chown /usr/local/bin/install_latest_ob_relay
_chown /usr/local/bin/install_latest_openbazaard
chmod 770 /usr/local/bin/{checkout_latest_git_tag,install_latest_openbazaard,install_latest_ob_relay}

# Update every night at 3AM
crontab -l -u openbazaar | { cat; echo "* 3 * * * /usr/local/bin/install_latest_ob_relay >> /home/openbazaar/logs/update_cron.log 2>&1"; } | crontab -u openbazaar - || true
crontab -l -u openbazaar | { cat; echo "* 3 * * * /usr/local/bin/install_latest_openbazaard >> /home/openbazaar/logs/update_cron.log 2>&1"; } | crontab -u openbazaar - || true

# Rotate logs daily
cat > /etc/logrotate.d/openbazaar <<-EOF
/home/openbazaar/logs/*.log {
  daily
  size 5M
  create 644 openbazaar openbazaar
  copytruncate
  rotate 14
  notifempty
  compress
  delaycompress
  missingok
  dateext
}
EOF

# Create directory for logs
_mkdir /home/openbazaar/logs

# Allow openbazaar user to control upstart jobs
sudo bash -c 'echo "openbazaar ALL=(ALL) NOPASSWD: /usr/sbin/service openbazaard start, /usr/sbin/service openbazaard stop, /usr/sbin/service openbazaard restart, /usr/sbin/service openbazaard status, /sbin/start openbazaard, /sbin/stop openbazaard, /sbin/restart openbazaard" | (EDITOR="tee -a" visudo -f /etc/sudoers.d/openbazaar)'
sudo bash -c 'echo "openbazaar ALL=(ALL) NOPASSWD: /usr/sbin/service ob-relay start, /usr/sbin/service ob-relay stop, /usr/sbin/service ob-relay restart, /usr/sbin/service ob-relay status, /sbin/start ob-relay, /sbin/stop ob-relay, /sbin/restart ob-relay" | (EDITOR="tee -a" visudo -f /etc/sudoers.d/openbazaar)'

# Generate SSL cert
_mkdir /home/openbazaar/ssl
openssl req -nodes -batch -x509 -newkey rsa:2048 -keyout /home/openbazaar/ssl/deploy.key -out /home/openbazaar/ssl/deploy.crt
_chown /home/openbazaar/ssl
chmod 700 /home/openbazaar/ssl
chmod 600 /home/openbazaar/ssl/{deploy.key,deploy.crt}

# Install git and nodejs
apt-key adv --keyserver keyserver.ubuntu.com --recv 68576280
apt-add-repository "deb https://deb.nodesource.com/node_6.x $(lsb_release -sc) main"
apt-get update
apt-get install -y git nodejs

# Install ob-relay
git clone https://github.com/OB1Company/ob-relay.git /home/openbazaar/ob-relay
install_latest_ob_relay
_chown /home/openbazaar/ob-relay

setState STARTING_OPENBAZAAR_RELAY

# Create Upstart script for ob-relay
cat > /etc/init/ob-relay.conf <<-EOF
description "OpenBazaar Server Relay"
setuid openbazaar
setgid openbazaar
chdir /home/openbazaar/ob-relay
respawn
start on runlevel [2345]
stop on runlevel [06]
env OB_RELAY_SSL_KEY_FILE="/home/openbazaar/ssl/deploy.key"
env OB_RELAY_SSL_CERT_FILE="/home/openbazaar/ssl/deploy.crt"
exec node app.js >> /home/openbazaar/logs/ob-relay.log 2>&1
EOF

# Start ob-relay
initctl reload-configuration && service ob-relay start

##
## Install required system packages
##

setState INSTALLING_SYSTEM_PACKAGES

# Update packages and do basic security hardening
apt-get upgrade -y

# Install fail2ban to block brute force SSH attempts
apt-get install -y fail2ban

# Disable incoming traffic except for the specified ports
ufw disable && ufw --force enable
ufw default deny incoming
ufw allow 22/tcp
ufw allow 8080/tcp
ufw allow 18466/tcp
ufw allow 18469/tcp
ufw allow 18470/tcp
ufw allow 18467/udp

# Setup monitoring for hanging nodes
apt-get install -y monit

cat > /etc/init/monit.conf <<-EOF
description "Monit service manager"
limit core unlimited unlimited
start on runlevel [2345]
stop on starting rc RUNLEVEL=[016]
expect daemon
respawn
exec /usr/bin/monit -c /etc/monit/monitrc
pre-stop exec /usr/bin/monit -c /etc/monit/monitrc quit
EOF

mkdir -p /etc/monit/bin
cat > /etc/monit/bin/openbazaar_check.sh <<-EOF
#!/bin/sh
curl --connect-timeout 60 -k -XPOST https://localhost:18469
EOF
chmod +x /etc/monit/bin/openbazaar_check.sh

cat > /etc/monit/monitrc <<-EOF
set daemon 300            # Run checks every 5 minutes
with start delay 1200     # Don't start checking until 20 minutes after startup

set logfile /var/log/monit.log
set idfile /var/lib/monit/id
set statefile /var/lib/monit/state

include /etc/monit/conf.d/*
EOF

cat > /etc/monit/conf.d/http <<-EOF
set httpd port 2812 and
  use address localhost
  allow localhost
EOF

cat > /etc/monit/conf.d/openbazaard <<-EOF
check program openbazaard with path "/etc/monit/bin/openbazaar_check.sh"
  start program = "/usr/sbin/service openbazaard start"
  stop program = "/usr/sbin/service openbazaard stop"
  if status != 0 4 times within 6 cycles then restart
  if 20 restarts within 40 cycles then unmonitor
EOF

initctl reload-configuration
service monit start
monit reload

# Install system packages we need
apt-get install -y python2.7 build-essential python-dev libffi-dev libssl-dev

# Install python 2.7.9
easy_install pip
pip install virtualenv
git clone https://github.com/yyuu/pyenv.git /home/openbazaar/.pyenv
git clone https://github.com/yyuu/pyenv-virtualenv.git /home/openbazaar/.pyenv/plugins/pyenv-virtualenv
cat >> /home/openbazaar/.bashrc <<-EOF
export PYENV_ROOT="\$HOME/.pyenv"
export PATH="\$HOME/.pyenv/bin:\$HOME/.pyenv/shims:$PATH"
eval "\$(pyenv init -)"
EOF

chown -R openbazaar:openbazaar /home/openbazaar

cd /home/openbazaar && su -c ".pyenv/bin/pyenv virtualenv 2.7.9 && .pyenv/bin/pyenv local 2.7.9 && .pyenv/bin/pyenv global 2.7.9" openbazaar

##
## Install OpenBazaar-Server
##

setState INSTALLING_OPENBAZAAR_SERVER

# Install OpenBazaar-Server
git clone https://github.com/OpenBazaar/OpenBazaar-Server.git /home/openbazaar/ob-server
virtualenv --python=/home/openbazaar/.pyenv/versions/2.7.9/bin/python /home/openbazaar/venv
install_latest_openbazaard
_chown /home/openbazaar

# Create config file
cat > /home/openbazaar/ob.cfg <<-EOF
[CONSTANTS]
DATA_FOLDER = /home/openbazaar/data/
TRANSACTION_FEE = 20400
RESOLVER = https://resolver.onename.com/
[LIBBITCOIN_SERVERS]
mainnet_server1 = tcp://libbitcoin1.openbazaar.org:9091
mainnet_server3 = tcp://libbitcoin3.openbazaar.org:9091
mainnet_server5 = tcp://obelisk.airbitz.co:9091
[LIBBITCOIN_SERVERS_TESTNET]
testnet_server2 = tcp://libbitcoin2.openbazaar.org:9091,baihZB[vT(dcVCwkhYLAzah<t2gJ>{3@k?+>T&^3
testnet_server4 = tcp://libbitcoin4.openbazaar.org:9091,<Z&{.=LJSPySefIKgCu99w.L%b^6VvuVp0+pbnOM
[AUTHENTICATION]
SSL = True
SSL_CERT = /home/openbazaar/ssl/deploy.crt
SSL_KEY = /home/openbazaar/ssl/deploy.key
USERNAME = admin
PASSWORD = {{obPassword}}
[MAINNET_SEEDS]
mainnet_seed2 = seed2.openbazaar.org:8080,8b17082a57d648894a5181cb6e1b8a6f5b3b7e1c347c0671abfcd7deb6f105fe
mainnet_seed3 = seed.obcentral.org:8080,f0ff751b27ddaa86a075aa09785c438cd2cebadb8f0f5a7e16f383911322d4ee
[TESTNET_SEEDS]
testnet_seed1 = seed.openbazaar.org:8080,5b44be5c18ced1bc9400fe5e79c8ab90204f06bebacc04dd9c70a95eaca6e117
EOF

_chown /home/openbazaar/ob.cfg

# Setup data directory and permissions
_mkdir /home/openbazaar/data
chmod -R 770 /home/openbazaar/data
chmod 660 /home/openbazaar/ob.cfg

setState STARTING_OPENBAZAAR_SERVER

# Create Upstart script for OpenBazaar-Server
cat > /etc/init/openbazaard.conf <<-EOF
description "OpenBazaar Server"
setuid openbazaar
setgid openbazaar
chdir /home/openbazaar
respawn
start on runlevel [2345]
stop on runlevel [06]
exec ./venv/bin/python ./ob-server/openbazaard.py start -a 0.0.0.0 >> ./logs/openbazaard.log 2>&1
EOF

# Start OpenBazaar-Server
initctl reload-configuration &&  service openbazaard start

setState READY
