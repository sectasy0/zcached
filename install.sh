#!/bin/bash

SERVICE_NAME="zcached"
USER_NAME="zcached"
GROUP_NAME="zcached"
BASE_DIR="/var"
LOG_DIR="$BASE_DIR/log/$SERVICE_NAME"
RUN_DIR="$BASE_DIR/run/$SERVICE_NAME"
LIB_DIR="$BASE_DIR/lib/$SERVICE_NAME"
BIN_DIR="/usr/bin/$SERVICE_NAME"
CONFIG_DIR="/etc/$SERVICE_NAME"
SERVICE_FILE=/etc/systemd/system/zcached.service

if [ -n "$ZIG_PATH" ]; then
	zig_command="$ZIG_PATH"
else
	zig_command="zig"
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "[error] this script must be run as root. please run again with 'sudo' or as root."
    exit 1
fi

if ! command -v systemctl > /dev/null 2>&1; then
    echo "[error] this script requires systemd, but it seems systemd is not present on this system."
    exit 1
fi

if ! getent group $GROUP_NAME > /dev/null 2>&1; then
    echo "[zcached] Creating system group: $GROUP_NAME"
    groupadd $GROUP_NAME
fi

if ! id -u $USER_NAME > /dev/null 2>&1; then
    echo "[zcached] Creating system user: $USER_NAME"
    useradd -r -g $GROUP_NAME -d $BASE_DIR/lib/$SERVICE_NAME -s /sbin/nologin -c "user for $SERVICE_NAME service" $USER_NAME
fi

echo "[zcached] Initializing directory setup..."

for DIR in $LOG_DIR $RUN_DIR $LIB_DIR $CONFIG_DIR; do
    if [ ! -d "$DIR" ]; then
        echo "[zcached] Ensuring directory exists: $DIR"
        mkdir -p $DIR
        chown $USER_NAME:$GROUP_NAME $DIR
        chmod 750 $DIR
    fi
done

echo "[zcached] Generating systemd service file: $SERVICE_FILE"
cat <<EOF > $SERVICE_FILE
	[Unit]
	Description=Lightweight and efficient in-memory caching system akin to databases like Redis.
	After=network.target
	Documentation=https://github.com/sectasy0/zcached/tree/master/docs

	[Service]
	Type=forking
	ExecStartPre=/usr/bin/rm -f $RUN_DIR/$SERVICE_NAME.pid
	ExecStart=/usr/bin/zcached -c $CONFIG_DIR/$SERVICE_NAME.conf -l $LOG_DIR/$SERVICE_NAME.log -d
	TimeoutStopSec=5
	TimeoutStartSec=5
	Restart=always
	User=$USER_NAME
	Group=$GROUP_NAME

	PrivateTmp=yes
	LimitNOFILE=65535
	PrivateDevices=yes
	ProtectHome=yes
	ReadOnlyDirectories=/
	ReadWritePaths=-$LIB_DIR
	ReadWritePaths=-$LOG_DIR
	ReadWritePaths=-$RUN_DIR

	NoNewPrivileges=true
	CapabilityBoundingSet=CAP_SETGID CAP_SETUID CAP_SYS_RESOURCE
	MemoryDenyWriteExecute=true
	ProtectKernelModules=true
	ProtectKernelTunables=true
	RestrictRealtime=true
	RestrictNamespaces=true
	RestrictAddressFamilies=AF_INET AF_UNIX

	[Install]
	WantedBy=multi-user.target
	Alias=$SERVICE_NAME.service
EOF

if command -v $zig_command &>/dev/null && [ "$($zig_command version)" = "0.13.0" ]; then
	echo "[zcached] Compiling executable.."
    $zig_command build --release=safe
	mv zig-out/bin/$SERVICE_NAME $BIN_DIR
	mv zcached.conf.example $CONFIG_DIR/zcached.conf
else
    echo "[error] zig-0.13.0 is not installed."
	exit 1
fi

echo "[zcached] Setup successfully completed."
