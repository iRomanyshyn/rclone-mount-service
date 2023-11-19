#!/bin/bash

# Rclone systemd mount service install script

# Check if the script is run as root
if [ "$EUID" -eq 0 ]; then
    echo "Error: This script should not be run as root. Please run it as a regular user. This script is designed to configure the mounting of remote resources in the user profile, ensuring that only the current user has access to their own files." >&2
    exit 1
fi

# Install rclone function
install_rclone() {
    read -p "Install rclone from the author's website? (y/n) " install
    if [ "$install" != "y" ]; then
        echo "To install rclone manually:"
        echo "Ubuntu/Debian: sudo apt install rclone"
        echo "Fedora: sudo dnf install rclone"
        echo "Manual: https://rclone.org/install/"
        exit 1
    fi
    if command -v curl; then
        curl https://rclone.org/install.sh | bash
    elif command -v wget; then
        wget -O- https://rclone.org/install.sh | bash
    fi
}

# Check if rclone is installed
if ! command -v rclone &>/dev/null; then
    # Check for curl or wget
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        echo "curl or wget required to install rclone"
        exit 1
    fi
    install_rclone
fi

# Get remote names from rclone config file
config_path="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"

if [ -f "$config_path" ]; then

  remotes=$(grep '\[.*\]' "$config_path" | tr -d '[]')

else
    echo "Error: Rclone configuration file not found. Run 'rclone config' to create a configuration file."
    exit 1
fi

# Validate and rename remotes
for remote in $remotes; do

  new_remote="${remote//[^A-Za-z0-9_-]/_}"  

  if [ "$remote" != "$new_remote" ]; then

    echo "Renaming remote $remote to $new_remote"

    sed -i "s/$remote/$new_remote/" "$config_path"
    
    remotes=$(grep '\[\w*\]' "$config_path" | tr -d '[]')

  fi

done

# Create systemd unit file
unit_file="${HOME}/.config/systemd/user/rclone@.service"

# Write the systemd unit file
cat > "$unit_file" <<EOF
[Unit]
Description=rclone: Remote FUSE filesystem for cloud storage config %i
Documentation=man:rclone(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p %h/mnt/%i
ExecStart=/usr/bin/rclone mount \\
        --vfs-cache-mode full \\
        --vfs-cache-max-size 1G \\
        --log-level INFO \\
        --log-file /tmp/rclone-%i.log \\
        --umask 077 \\
        %i: %h/mnt/%i
ExecStop=/bin/fusermount -u %h/mnt/%i
Restart=on-failure
RestartSec=1m
StandardOutput=syslog
StandardError=syslog

[Install]
WantedBy=default.target
EOF

# Reload systemd and enable services
systemctl --user daemon-reload

for remote in $remotes; do
  systemctl --user enable --now "rclone@${remote}"
done

# Display completion message and usage instructions
echo $'\e[92mInstallation completed. Services started for all remotes.\e[0m'
echo "To add additional remotes, run the following command:"
echo -e $'\e[96mrclone config\e[0m'
echo "Follow the prompts to add a new remote. After adding, run the script again to start the service for the new remote."
