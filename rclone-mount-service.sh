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

usage() {
    cat <<'EOF'
Usage:
  rclone-mount-service.sh                  Select remotes interactively
  rclone-mount-service.sh --all            Mount all file-defined remotes
  rclone-mount-service.sh REMOTE [...]     Mount the named remotes

REMOTE may be written with or without the trailing colon shown by
`rclone listremotes`. Quote names containing spaces.
EOF
}

resolve_config_path() {
    local config_dir
    CONFIG_PATH=${RCLONE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf}
    case "$CONFIG_PATH" in
        /*) ;;
        *) CONFIG_PATH="$PWD/$CONFIG_PATH" ;;
    esac
    if [ ! -f "$CONFIG_PATH" ]; then
        echo "Error: Rclone configuration file not found: $CONFIG_PATH" >&2
        echo "Run 'rclone config' to create it or set RCLONE_CONFIG." >&2
        return 1
    fi

    # Normalize the parent path while preserving a configuration-file symlink.
    config_dir=$(dirname -- "$CONFIG_PATH") || return 1
    config_dir=$(cd -- "$config_dir" && pwd -P) || return 1
    CONFIG_PATH="$config_dir/${CONFIG_PATH##*/}"
}

load_remotes() {
    local output remote
    AVAILABLE_REMOTES=()
    if ! output=$("$RCLONE_BIN" listremotes --config "$CONFIG_PATH" --source file); then
        echo "Error: Failed to list file-defined Rclone remotes." >&2
        echo "This script requires an Rclone version supporting 'listremotes --source file'." >&2
        return 1
    fi
    while IFS= read -r remote; do
        [ -n "$remote" ] || continue
        AVAILABLE_REMOTES+=("${remote%:}")
    done <<< "$output"
    if [ "${#AVAILABLE_REMOTES[@]}" -eq 0 ]; then
        echo "Error: No file-defined remotes found in $CONFIG_PATH" >&2
        return 1
    fi
}

remote_exists() {
    local candidate
    for candidate in "${AVAILABLE_REMOTES[@]}"; do
        [ "$candidate" = "$1" ] && return 0
    done
    return 1
}

add_selected_remote() {
    local selected
    remote_exists "$1" || {
        echo "Error: Unknown remote: $1" >&2
        return 1
    }
    for selected in "${SELECTED_REMOTES[@]}"; do
        [ "$selected" = "$1" ] && return 0
    done
    SELECTED_REMOTES+=("$1")
}

stdin_is_terminal() {
    [ -t 0 ]
}

select_remotes() {
    local argument answer item index
    local -a choices
    SELECTED_REMOTES=()

    if [ "$#" -gt 0 ]; then
        case "$1" in
            -h|--help)
                usage
                [ "$#" -eq 1 ] && return 2
                echo "Error: Help cannot be combined with remote names." >&2
                return 1
                ;;
            --all)
                [ "$#" -eq 1 ] || {
                    echo "Error: --all cannot be combined with remote names." >&2
                    return 1
                }
                SELECTED_REMOTES=("${AVAILABLE_REMOTES[@]}")
                return 0
                ;;
            --) shift ;;
        esac
        [ "$#" -gt 0 ] || {
            echo "Error: No remotes specified after --." >&2
            return 1
        }
        for argument in "$@"; do
            add_selected_remote "${argument%:}" || return 1
        done
        return 0
    fi

    if ! stdin_is_terminal; then
        echo "Error: No remotes specified in non-interactive mode. Use --all or pass remote names." >&2
        return 1
    fi
    echo "Available file-defined remotes:"
    for index in "${!AVAILABLE_REMOTES[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${AVAILABLE_REMOTES[index]}"
    done
    read -r -p "Select remotes by number (space-separated), or type 'all': " answer || return 1
    if [ "$answer" = all ]; then
        SELECTED_REMOTES=("${AVAILABLE_REMOTES[@]}")
        return 0
    fi
    read -r -a choices <<< "$answer"
    for item in "${choices[@]}"; do
        case "$item" in
            ''|*[!0-9]*)
                echo "Error: Invalid selection: $item" >&2
                return 1
                ;;
        esac
        index=$((10#$item))
        if [ "$index" -lt 1 ] || [ "$index" -gt "${#AVAILABLE_REMOTES[@]}" ]; then
            echo "Error: Selection out of range: $item" >&2
            return 1
        fi
        add_selected_remote "${AVAILABLE_REMOTES[index - 1]}" || return 1
    done
    [ "${#SELECTED_REMOTES[@]}" -gt 0 ] || {
        echo "Error: No remotes selected." >&2
        return 1
    }
}

escape_systemd_exec_value() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    value=${value//\$/\$\$}
    printf '%s' "$value"
}

service_unit() {
    local digest
    digest=$(printf '%s\0%s\0' "$CONFIG_PATH" "$1" | sha256sum) || return 1
    digest=${digest%% *}
    case "$digest" in
        *[!0-9a-f]*|'')
            echo "Error: sha256sum returned an invalid digest." >&2
            return 1
            ;;
    esac
    printf 'rclone-%s.service\n' "${digest:0:24}"
}

write_unit_file() {
    local remote=$1 unit=$2 unit_dir unit_file
    local rclone_exec config_exec remote_exec
    # An invocation-only XDG_CONFIG_HOME may not be in the running user
    # manager's search path. This conventional directory is stable.
    unit_dir="$HOME/.config/systemd/user"
    unit_file="$unit_dir/$unit"
    mkdir -p -- "$unit_dir" || return 1
    rclone_exec=$(escape_systemd_exec_value "$RCLONE_BIN") || return 1
    config_exec=$(escape_systemd_exec_value "$CONFIG_PATH") || return 1
    remote_exec=$(escape_systemd_exec_value "$remote") || return 1

    cat > "$unit_file" <<EOF
[Unit]
Description=Rclone remote mount ${unit%.service}
Documentation=man:rclone(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p "%h/mnt/${unit%.service}"
ExecStart=/usr/bin/env -- "$rclone_exec" mount \\
        --config "$config_exec" \\
        --vfs-cache-mode full \\
        --vfs-cache-max-size 1G \\
        --log-level INFO \\
        --log-file "/tmp/${unit%.service}.log" \\
        --umask 077 \\
        -- "$remote_exec:" "%h/mnt/${unit%.service}"
ExecStop=/bin/fusermount -u "%h/mnt/${unit%.service}"
Restart=on-failure
RestartSec=1m
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
}

write_selected_units() {
    local remote unit
    for remote in "${SELECTED_REMOTES[@]}"; do
        unit=$(service_unit "$remote") || return 1
        write_unit_file "$remote" "$unit" || return 1
    done
}

enable_selected_remotes() {
    local remote unit failed=0
    systemctl --user daemon-reload || return 1
    for remote in "${SELECTED_REMOTES[@]}"; do
        unit=$(service_unit "$remote") || return 1
        # restart also starts an inactive unit and guarantees that rerunning
        # the installer applies the freshly written service definition.
        if systemctl --user enable "$unit" && systemctl --user restart "$unit"; then
            printf 'Started %s as %s (mountpoint: %s/mnt/%s)\n' \
                "$remote" "$unit" "$HOME" "${unit%.service}"
        else
            echo "Error: Failed to enable or start $unit" >&2
            failed=1
        fi
    done
    return "$failed"
}

main() {
    if [ "$#" -eq 1 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then
        usage
        return 0
    fi
    # Check if the script is run as root
    if [ "$EUID" -eq 0 ]; then
        echo "Error: This script should not be run as root. Please run it as a regular user. This script is designed to configure the mounting of remote resources in the user profile, ensuring that only the current user has access to their own files." >&2
        return 1
    fi

    ensure_rclone || return 1
    command -v sha256sum >/dev/null || {
        echo "Error: sha256sum is required." >&2
        return 1
    }
    resolve_config_path || return 1
    load_remotes || return 1
    select_remotes "$@"
    case $? in
        0) ;;
        2) return 0 ;;
        *) return 1 ;;
    esac
    write_selected_units || return 1
    enable_selected_remotes || return 1

    echo $'\e[92mInstallation completed. Selected services are running.\e[0m'
    echo "To add additional remotes, run the following command:"
    echo -e $'\e[96mrclone config\e[0m'
    echo "Follow the prompts to add a new remote. After adding, run the script again to start the service for the new remote."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
