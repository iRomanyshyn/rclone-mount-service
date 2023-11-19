#!/bin/bash

# Rclone systemd mount service install script

# Check if the script is run as root
if [ "$EUID" -eq 0 ]; then
    echo "Error: This script should not be run as root. Please run it as a regular user. This script is designed to configure the mounting of remote resources in the user profile, ensuring that only the current user has access to their own files." >&2
    exit 1
fi

# Allowed remote name characters
allowed_chars="[A-Za-z0-9_-]"

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
    remotes=$(grep '\[\w*\]' "$config_path" | tr -d '[]')
else
    echo "Error: Rclone configuration file not found. Run 'rclone config' to create a configuration file."
    exit 1
fi

# Function to sanitize remote name
sanitize_remote_name() {
    local dirty_name="$1"
    echo "$dirty_name" | sed 's/[^A-Za-z0-9_-]/_/g'
}

# Validate remote names and rename if needed
for remote in $remotes; do
  if ! [[ $remote =~ $regex ]]; then
    echo "Invalid remote name: $remote"
    echo "Allowed characters: $allowed_chars"
    read -p "Would you like to automatically rename this remote? (y/n) " auto_rename
    if [ "$auto_rename" == "y" ]; then
      new_remote=$(echo "$remote" | tr -cd "$allowed_chars")
      echo "Automatically renaming the remote to $new_remote"
      
      # Replace the old remote name with the new one in the rclone config file
      sed -i "s/\[$remote\]/\[$new_remote\]/" "$config_path"
    else
      read -p "To manually rename the remote, run 'rclone config', select 'r' to rename, choose the number for the remote, and provide the new name."
    fi
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
ExecStartPre=/bin/bash -c '[[ -d %h/mnt/%i ]] || mkdir -p %h/mnt/%i'
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

[Install]
WantedBy=default.target
EOF

# Reload systemd units
systemctl --user daemon-reload

# Enable and start services for all remotes
for remote in $remotes; do
    systemctl --user enable --now "rclone@${remote}"
done

# Display completion message and usage instructions
echo $'\e[92mInstallation completed. Services started for all remotes.\e[0m'
echo "To add additional remotes, run the following command:"
echo -e $'\e[96mrclone config\e[0m'
echo "Follow the prompts to add a new remote. After adding, run the script again to start the service for the new remote."
