#!/bin/bash -vx
#
# Install, configure and start a new Minecraft server
# This supports Ubuntu and Amazon Linux 2 flavors of Linux (maybe/probably others but not tested).

set -e

# Determine linux distro
if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS=Debian
    VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    ...
elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    ...
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    VER=$(uname -r)
fi

# Update OS and install start script
ubuntu_linux_setup() {
  export SSH_USER="ubuntu"
  export DEBIAN_FRONTEND=noninteractive
  /usr/bin/apt-get update
  /usr/bin/apt-get -yq install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" default-jre wget awscli jq
  /bin/cat <<"__UPG__" > /etc/apt/apt.conf.d/10periodic
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
__UPG__

  # Init script for starting, stopping
  cat <<INIT > /etc/init.d/minecraft
#!/bin/bash
# Short-Description: Minecraft server

start() {
  echo "Starting minecraft server from /home/minecraft..."
  start-stop-daemon --start --quiet  --pidfile ${mc_root}/minecraft.pid -m -b -c $SSH_USER -d ${mc_root} --exec /usr/bin/java -- -Xmx${java_mx_mem} -Xms${java_ms_mem} -jar $MINECRAFT_JAR nogui
}

stop() {
  echo "Stopping minecraft server..."
  start-stop-daemon --stop --pidfile ${mc_root}/minecraft.pid
}

case \$1 in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    sleep 5
    start
    ;;
esac
exit 0
INIT

  # Start up on reboot
  /bin/chmod +x /etc/init.d/minecraft
  /usr/sbin/update-rc.d minecraft defaults

}

# Update OS and install start script
amazon_linux_setup() {
    export SSH_USER="ec2-user"
    /usr/bin/yum install java-1.8.0 yum-cron wget awscli jq -y
    /bin/sed -i -e 's/update_cmd = default/update_cmd = security/'\
                -e 's/apply_updates = no/apply_updates = yes/'\
                -e 's/emit_via = stdio/emit_via = email/' /etc/yum/yum-cron.conf
    chkconfig yum-cron on
    service yum-cron start
    /usr/bin/yum upgrade -y

    cat <<SYSTEMD > /etc/systemd/system/minecraft.service
[Unit]
Description=Minecraft Server
After=network.target

[Service]
Type=simple
User=$SSH_USER
WorkingDirectory=${mc_root}
ExecStart=/usr/bin/java -Xmx${java_mx_mem} -Xms${java_ms_mem} -jar $MINECRAFT_JAR nogui
Restart=on-abort

[Install]
WantedBy=multi-user.target
SYSTEMD

  # Start on boot
  /usr/bin/systemctl enable minecraft

}

### Thanks to https://github.com/kenoir for pointing out that as of v15 (?) we have to
### use the Mojang version_manifest.json to find java download location
### See https://minecraft.gamepedia.com/Version_manifest.json
download_minecraft_server() {

  WGET=$(which wget)

  # version_manifest.json lists available MC versions
  $WGET -O ${mc_root}/version_manifest.json https://launchermeta.mojang.com/mc/game/version_manifest.json

  # Find latest version number if user wants that version (the default)
  if [[ "${mc_version}" == "latest" ]]; then
    MC_VERS=$(jq -r '.["latest"]["'"${mc_type}"'"]' ${mc_root}/version_manifest.json)
  fi

  # Index version_manifest.json by the version number and extract URL for the specific version manifest
  VERSIONS_URL=$(jq -r '.["versions"][] | select(.id == "'"$MC_VERS"'") | .url' ${mc_root}/version_manifest.json)
  # From specific version manifest extract the server JAR URL
  SERVER_URL=$(curl -s $VERSIONS_URL | jq -r '.downloads | .server | .url')
  # And finally download it to our local MC dir
  $WGET -O ${mc_root}/$MINECRAFT_JAR $SERVER_URL

}

MINECRAFT_JAR="minecraft_server.jar"
case $OS in
  Ubuntu*)
    ubuntu_linux_setup
    ;;
  Amazon*)
    amazon_linux_setup
    ;;
  *)
    echo "$PROG: unsupported OS $OS"
    exit 1
esac

# Create mc dir, sync S3 to it and download mc if not already there (from S3)
/bin/mkdir -p ${mc_root}
/usr/bin/aws s3 sync s3://${mc_bucket} ${mc_root}

# Download server if it doesn't exist on S3 already (existing from previous install)
# To force a new server version, remove the server JAR from S3 bucket
if [[ ! -e "${mc_root}/$MINECRAFT_JAR" ]]; then
  download_minecraft_server
fi

# Cron job to sync data to S3 every five mins
/bin/cat <<CRON > /etc/cron.d/minecraft
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:${mc_root}
*/${mc_backup_freq} * * * *  $SSH_USER  /usr/bin/aws s3 sync ${mc_root}  s3://${mc_bucket}
CRON

# Update minecraft EULA
/bin/cat >${mc_root}/eula.txt<<EULA
#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://account.mojang.com/documents/minecraft_eula).
#Tue Jan 27 21:40:00 UTC 2015
eula=true
EULA

# Update minecraft server properties
/bin/cat >${mc_root}/server.properties<<SERVER
#Minecraft server properties
#Mon Jul 10 00:30:50 UTC 2023
enable-jmx-monitoring=false
level-seed=
rcon.port=25575
enable-command-block=true
gamemode=creative
enable-query=false
generator-settings={}
enforce-secure-profile=false
level-name=world
motd=Welcome to Minecraft hosted by Saranicole\!
query.port=25565
texture-pack=
pvp=false
generate-structures=true
max-chained-neighbor-updates=1000000
difficulty=easy
network-compression-threshold=256
max-tick-time=60000
require-resource-pack=false
max-players=4
use-native-transport=true
online-mode=true
enable-status=true
allow-flight=false
initial-disabled-packs=
broadcast-rcon-to-ops=true
view-distance=10
max-build-height=256
server-ip=
resource-pack-prompt=
allow-nether=true
server-port=25565
enable-rcon=false
sync-chunk-writes=true
op-permission-level=4
prevent-proxy-connections=false
hide-online-players=false
resource-pack=
entity-broadcast-range-percentage=100
simulation-distance=10
player-idle-timeout=0
rcon.password=minecraft
force-gamemode=false
rate-limit=0
hardcore=false
white-list=true
broadcast-console-to-ops=true
spawn-npcs=true
previews-chat=false
spawn-animals=true
snooper-enabled=true
function-permission-level=2
initial-enabled-packs=vanilla
level-type=default
text-filtering-config=
spawn-monsters=true
enforce-whitelist=false
resource-pack-sha1=
spawn-protection=16
max-world-size=10000
SERVER

# Update minecraft ops
/bin/cat >${mc_root}/ops.json<<OPS
[
  {
    "uuid": "1b5cef46-14e1-4569-afad-818d9ae4ed45",
    "name": "nikkiwhitten",
    "level": 4,
    "bypassesPlayerLimit": false
  },
  {
    "uuid": "7fabeb75-cff7-45c7-a342-3643968c6b8c",
    "name": "HauntedHorse",
    "level": 4,
    "bypassesPlayerLimit": false
  },
  {
    "uuid": "c95695cd-e2f0-4750-aea0-fdddd07abcdc",
    "name": "saranicole1980",
    "level": 4,
    "bypassesPlayerLimit": false
  },
  {
    "uuid": "be8c067f-f686-4121-9f91-77dab823c697",
    "name": "BlockLobster12",
    "level": 4,
    "bypassesPlayerLimit": false
  },
  {
    "uuid": "b2350db3-2456-401e-905a-eaf195907591",
    "name": "Bruns14",
    "level": 4,
    "bypassesPlayerLimit": false
  },
  {
    "uuid": "34331a76-a5f9-4cdc-b699-c23469788d4e",
    "name": "legendofyoni",
    "level": 4,
    "bypassesPlayerLimit": false
  }
]
OPS

# Update minecraft ops
/bin/cat >${mc_root}/whitelist.json<<WHITELIST
[
  {
    "uuid": "1b5cef46-14e1-4569-afad-818d9ae4ed45",
    "name": "nikkiwhitten"
  },
  {
    "uuid": "2e587169-3fb7-4e6a-af76-94bbf900fe03",
    "name": "junipercraft"
  },
  {
    "uuid": "7fabeb75-cff7-45c7-a342-3643968c6b8c",
    "name": "HauntedHorse"
  },
  {
    "uuid": "c95695cd-e2f0-4750-aea0-fdddd07abcdc",
    "name": "saranicole1980"
  },
  {
    "uuid": "be8c067f-f686-4121-9f91-77dab823c697",
    "name": "BlockLobster12"
  },
  {
    "uuid": "b2350db3-2456-401e-905a-eaf195907591",
    "name": "Bruns14"
  },
  {
    "uuid": "34331a76-a5f9-4cdc-b699-c23469788d4e",
    "name": "legendofyoni"
  }
]
WHITELIST

# Not root
/bin/chown -R $SSH_USER ${mc_root}

# Start the server
case $OS in
  Ubuntu*)
    /etc/init.d/minecraft start
    ;;
  Amazon*)
    /usr/bin/systemctl start minecraft
    ;;
esac

exit 0

