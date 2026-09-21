#!/bin/bash

# Rclone systemd mount service install script

# Return the current distribution and its parent families.
distribution_ids() (
    local ID= ID_LIKE=
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi
    printf '%s\n' "$ID $ID_LIKE"
)

# Print: package manager, package format, official Rclone architecture.
# Return failure when there is no supported package route.
rclone_package() {
    local distro_ids distro manager= format= arch
    distro_ids=$(distribution_ids) || return 1
    for distro in $distro_ids; do
        case "$distro" in
            debian|ubuntu)
                if command -v apt >/dev/null && command -v dpkg >/dev/null; then
                    manager=apt; format=deb
                fi
                ;;
            fedora|rhel|centos)
                if command -v dnf >/dev/null && command -v rpm >/dev/null; then
                    manager=dnf; format=rpm
                fi
                ;;
            opensuse*|suse|sles|sled)
                if command -v zypper >/dev/null && command -v rpm >/dev/null; then
                    manager=zypper; format=rpm
                fi
                ;;
        esac
        [ -z "$manager" ] || break
    done
    [ -n "$manager" ] || return 1

    # Query the package architecture, not the kernel (which may be 64-bit
    # while the userspace is 32-bit).
    if [ "$format" = deb ]; then
        arch=$(dpkg --print-architecture) || return 1
        case "$arch" in
            amd64|arm64) ;;
            i386) arch=386 ;;
            armhf) arch=arm-v6 ;;
            armel) arch=arm ;;
            *) return 1 ;;
        esac
    else
        arch=$(rpm --eval '%{_arch}') || return 1
        case "$arch" in
            x86_64) arch=amd64 ;;
            aarch64) arch=arm64 ;;
            i386|i486|i586|i686) arch=386 ;;
            armv6hl) arch=arm-v6 ;;
            armv7hl|armv7hnl) arch=arm-v7 ;;
            *) return 1 ;;
        esac
    fi
    printf '%s %s %s\n' "$manager" "$format" "$arch"
}

download_file() {
    if command -v curl >/dev/null; then
        curl --fail --location --show-error --output "$2" "$1"
    elif command -v wget >/dev/null; then
        wget --output-document="$2" "$1"
    else
        echo "Error: curl or wget is required to download Rclone." >&2
        return 1
    fi
}

install_rclone() (
    local package_spec manager format arch method url answer tmp_dir artifact status
    if package_spec=$(rclone_package); then
        read -r manager format arch <<< "$package_spec"
        method="official .$format package using $manager"
        url="https://downloads.rclone.org/rclone-current-linux-$arch.$format"
    else
        method="official install.sh (no supported package route found)"
        url=https://rclone.org/install.sh
        # Never use the script to overwrite a package-managed installation
        # that happens to be absent from this user's PATH.
        if { command -v rpm >/dev/null && rpm -q rclone >/dev/null 2>&1; } ||
           { command -v dpkg-query >/dev/null &&
             [ "$(dpkg-query -W -f='${Status}' rclone 2>/dev/null)" = 'install ok installed' ]; }; then
            echo "Error: Rclone is package-managed but missing from PATH. Repair that installation first." >&2
            return 1
        fi
    fi
    if ! command -v sudo >/dev/null; then
        echo "Error: sudo is required. Install Rclone manually: https://rclone.org/install/" >&2
        return 1
    fi
    if ! read -r -p "Install Rclone via $method? [y/N] " answer; then
        return 1
    fi
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Installation cancelled. Manual instructions: https://rclone.org/install/"; return 1 ;;
    esac

    tmp_dir=$(mktemp -d) || return 1
    trap 'rm -rf -- "$tmp_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    artifact="$tmp_dir/rclone.${format:-sh}"
    if ! download_file "$url" "$artifact"; then
        echo "Error: Rclone download failed. No installer was run." >&2
        return 1
    fi

    case "$manager" in
        apt) sudo apt install "$artifact" ;;
        dnf) sudo dnf install "$artifact" ;;
        zypper) sudo zypper install "$artifact" ;;
        *) sudo bash "$artifact" ;;
    esac
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: Rclone installation failed or was cancelled (exit $status). No alternative installer will be run." >&2
        return "$status"
    fi
)

ensure_rclone() {
    if ! command -v rclone >/dev/null; then
        install_rclone || return 1
        hash -r
    fi
    RCLONE_BIN=$(type -P rclone) || {
        echo "Error: Rclone executable was not found after installation." >&2
        return 1
    }
    # systemd needs an absolute path, but the final symlink must be preserved:
    # multicall launchers can select Rclone based on the invoked command name.
    case "$RCLONE_BIN" in
        /*) ;;
        *) RCLONE_BIN="$PWD/$RCLONE_BIN" ;;
    esac
    if ! "$RCLONE_BIN" version || ! "$RCLONE_BIN" mount --help >/dev/null; then
        echo "Error: Rclone is not working or does not support mount." >&2
        return 1
    fi
}

main() {
    # Check if the script is run as root
    if [ "$EUID" -eq 0 ]; then
        echo "Error: This script should not be run as root. Please run it as a regular user. This script is designed to configure the mounting of remote resources in the user profile, ensuring that only the current user has access to their own files." >&2
        return 1
    fi

    ensure_rclone || return 1

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
    mkdir -p -- "${unit_file%/*}" || return 1

    # Escape the executable path for systemd's quoted ExecStart syntax.
    rclone_exec=${RCLONE_BIN//\\/\\\\}
    rclone_exec=${rclone_exec//\"/\\\"}
    rclone_exec=${rclone_exec//%/%%}
    rclone_exec=${rclone_exec//\$/\$\$}

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
ExecStart="$rclone_exec" mount \\
        --vfs-cache-mode full \\
        --vfs-cache-max-size 1G \\
        --log-level INFO \\
        --log-file /tmp/rclone-%i.log \\
        --umask 077 \\
        %i: %h/mnt/%i
ExecStop=/bin/fusermount -u %h/mnt/%i
Restart=on-failure
RestartSec=1m
StandardOutput=journal
StandardError=journal

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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
