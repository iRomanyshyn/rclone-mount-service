#!/bin/bash

# Rclone systemd mount service install script

# Return the current distribution and its parent families.
distribution_ids() (
    local ID='' ID_LIKE=''
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi
    printf '%s\n' "$ID $ID_LIKE"
)

# Print: package manager, package format, official Rclone architecture.
# Return failure when there is no supported package route.
rclone_package() {
    local distro_ids distro manager='' format='' arch
    distro_ids=$(distribution_ids) || return 1
    # Intentional word splitting: ID_LIKE is a space-separated list.
    # shellcheck disable=SC2086
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

verify_release_checksum() {
    local artifact=$1 sums_file=$2 expected_name=$3 hash name expected='' actual
    while IFS=' ' read -r hash name; do
        if [ "$name" = "$expected_name" ]; then
            expected=$hash
            break
        fi
    done < "$sums_file"
    if [ "${#expected}" -ne 64 ]; then
        echo "Error: No valid SHA-256 checksum found for $expected_name." >&2
        return 1
    fi
    case "$expected" in
        *[!0-9a-f]*)
            echo "Error: Invalid SHA-256 checksum for $expected_name." >&2
            return 1
            ;;
    esac
    actual=$(sha256sum -- "$artifact") || return 1
    actual=${actual%% *}
    if [ "$actual" != "$expected" ]; then
        echo "Error: SHA-256 verification failed for $expected_name." >&2
        return 1
    fi
}

install_rclone() (
    local package_spec manager format arch method url answer tmp_dir artifact status
    local version version_file filename sums_file
    if package_spec=$(rclone_package); then
        read -r manager format arch <<< "$package_spec"
        method="official .$format package using $manager"
        command -v sha256sum >/dev/null || {
            echo "Error: sha256sum is required to verify the Rclone package." >&2
            return 1
        }
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

    if [ -n "$manager" ]; then
        version_file="$tmp_dir/version.txt"
        if ! download_file https://downloads.rclone.org/version.txt "$version_file"; then
            echo "Error: Failed to determine the current Rclone release." >&2
            return 1
        fi
        read -r _ version < "$version_file" || return 1
        if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Error: Invalid Rclone release version: $version" >&2
            return 1
        fi
        filename="rclone-$version-linux-$arch.$format"
        url="https://downloads.rclone.org/$version/$filename"
        sums_file="$tmp_dir/SHA256SUMS"
        artifact="$tmp_dir/$filename"
        if ! download_file "$url" "$artifact" ||
           ! download_file "https://downloads.rclone.org/$version/SHA256SUMS" "$sums_file"; then
            echo "Error: Rclone download failed. No installer was run." >&2
            return 1
        fi
        verify_release_checksum "$artifact" "$sums_file" "$filename" || return 1
    else
        artifact="$tmp_dir/rclone.sh"
        if ! download_file "$url" "$artifact"; then
            echo "Error: Rclone download failed. No installer was run." >&2
            return 1
        fi
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
  rclone-mount-service.sh [OPTIONS] [REMOTE ...]
  rclone-mount-service.sh --prune

REMOTE may be written with or without the trailing colon shown by
`rclone listremotes`. Quote names containing spaces.

Options:
  --all                       Select every file-defined remote
  --mountpoint ABSOLUTE_PATH  Custom mountpoint (one remote only)
  --subdir PATH               Mount a path below each selected remote
  --read-only                 Prevent writes through the mount
  --vfs-cache-mode MODE       off, minimal, writes, or full (default: full)
  --vfs-cache-max-size SIZE   Per-mount cache limit (default: 1G)
  --prune                     Remove managed units for deleted remotes
  -h, --help                  Show this help

Without REMOTE or --all, an interactive selector is shown. Use -- before a
remote name that begins with a dash. Options are persisted in each generated
service; rerun the command for that remote to change them.
EOF
}

parse_options() {
    SELECT_ALL=0
    PRUNE_ONLY=0
    MOUNTPOINT=
    SUBDIR=
    READ_ONLY=0
    VFS_CACHE_MODE=full
    VFS_CACHE_MAX_SIZE=1G
    MOUNT_OPTIONS_SET=0
    REMOTE_ARGS=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                return 2
                ;;
            --all)
                SELECT_ALL=1
                ;;
            --mountpoint|--subdir|--vfs-cache-mode|--vfs-cache-max-size)
                [ "$#" -ge 2 ] || {
                    echo "Error: $1 requires a value." >&2
                    return 1
                }
                case "$1" in
                    --mountpoint) MOUNTPOINT=$2 ;;
                    --subdir) SUBDIR=$2 ;;
                    --vfs-cache-mode) VFS_CACHE_MODE=$2 ;;
                    --vfs-cache-max-size) VFS_CACHE_MAX_SIZE=$2 ;;
                esac
                MOUNT_OPTIONS_SET=1
                shift
                ;;
            --read-only)
                READ_ONLY=1
                MOUNT_OPTIONS_SET=1
                ;;
            --prune)
                PRUNE_ONLY=1
                ;;
            --)
                shift
                REMOTE_ARGS+=("$@")
                break
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
            *)
                REMOTE_ARGS+=("$1")
                ;;
        esac
        shift
    done

    case "$VFS_CACHE_MODE" in
        off|minimal|writes|full) ;;
        *)
            echo "Error: Invalid VFS cache mode: $VFS_CACHE_MODE" >&2
            return 1
            ;;
    esac
    [ -n "$VFS_CACHE_MAX_SIZE" ] || {
        echo "Error: --vfs-cache-max-size cannot be empty." >&2
        return 1
    }
    if [ "$PRUNE_ONLY" -eq 1 ] &&
       { [ "$SELECT_ALL" -eq 1 ] || [ "${#REMOTE_ARGS[@]}" -gt 0 ] ||
         [ "$MOUNT_OPTIONS_SET" -eq 1 ]; }; then
        echo "Error: --prune cannot be combined with mount selections or options." >&2
        return 1
    fi
    if [ "$SELECT_ALL" -eq 1 ] && [ "${#REMOTE_ARGS[@]}" -gt 0 ]; then
        echo "Error: --all cannot be combined with remote names." >&2
        return 1
    fi
    if [ -n "$MOUNTPOINT" ]; then
        case "$MOUNTPOINT" in
            /*) ;;
            *)
                echo "Error: --mountpoint must be an absolute path." >&2
                return 1
                ;;
        esac
    fi
    case "$MOUNTPOINT$SUBDIR$VFS_CACHE_MAX_SIZE" in
        *$'\n'*|*$'\r'*)
            echo "Error: Option values cannot contain line breaks." >&2
            return 1
            ;;
    esac
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
    if [ "${#AVAILABLE_REMOTES[@]}" -eq 0 ] && [ "${PRUNE_ONLY:-0}" -ne 1 ]; then
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

    if [ "${SELECT_ALL:-0}" -eq 1 ]; then
        SELECTED_REMOTES=("${AVAILABLE_REMOTES[@]}")
        return 0
    fi
    if [ "$#" -gt 0 ]; then
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

validate_selection_options() {
    if [ -n "${MOUNTPOINT:-}" ] && [ "${#SELECTED_REMOTES[@]}" -ne 1 ]; then
        echo "Error: --mountpoint requires exactly one selected remote." >&2
        return 1
    fi
}

escape_systemd_exec_value() {
    local value=$1
    case "$value" in
        *$'\n'*|*$'\r'*)
            echo "Error: systemd values cannot contain line breaks." >&2
            return 1
            ;;
    esac
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    value=${value//\$/\$\$}
    printf '%s' "$value"
}

config_digest() {
    local digest
    digest=$(printf '%s\0' "$CONFIG_PATH" | sha256sum) || return 1
    digest=${digest%% *}
    if [ "${#digest}" -ne 64 ]; then
        echo "Error: sha256sum returned an invalid digest." >&2
        return 1
    fi
    case "$digest" in
        *[!0-9a-f]*|'')
            echo "Error: sha256sum returned an invalid digest." >&2
            return 1
            ;;
    esac
    printf '%s\n' "$digest"
}

service_unit() {
    local digest
    digest=$(printf '%s\0%s\0' "$CONFIG_PATH" "$1" | sha256sum) || return 1
    digest=${digest%% *}
    if [ "${#digest}" -ne 64 ]; then
        echo "Error: sha256sum returned an invalid digest." >&2
        return 1
    fi
    case "$digest" in
        *[!0-9a-f]*)
            echo "Error: sha256sum returned an invalid digest." >&2
            return 1
            ;;
    esac
    printf 'rclone-%s.service\n' "${digest:0:24}"
}

find_fusermount() {
    local candidate
    for candidate in /usr/bin/fusermount3 /bin/fusermount3 \
                     /usr/bin/fusermount /bin/fusermount; do
        if [ -x "$candidate" ]; then
            return 0
        fi
    done
    echo "Error: fusermount3 or fusermount is required (install FUSE 3 or FUSE 2)." >&2
    return 1
}

check_fuse() {
    if [ ! -e /dev/fuse ]; then
        echo "Error: /dev/fuse is unavailable. Load FUSE and ensure the device exists." >&2
        return 1
    fi
    if [ ! -r /dev/fuse ] || [ ! -w /dev/fuse ]; then
        echo "Error: The current user cannot access /dev/fuse." >&2
        return 1
    fi
    find_fusermount
}

unit_directory() {
    printf '%s/.config/systemd/user\n' "$HOME"
}

cache_root() {
    local root=${XDG_CACHE_HOME:-$HOME/.cache}
    case "$root" in
        /*) ;;
        *) root="$PWD/$root" ;;
    esac
    printf '%s/rclone-mount-service\n' "$root"
}

mountpoint_for() {
    local unit=$1
    if [ -n "${MOUNTPOINT:-}" ]; then
        printf '%s\n' "$MOUNTPOINT"
    else
        printf '%s/mnt/%s\n' "$HOME" "${unit%.service}"
    fi
}

write_unit_file() {
    local remote=$1 unit=$2 unit_dir unit_file temporary_unit
    local rclone_exec config_exec source_exec mount_exec cache_exec
    local source mountpoint cache_dir config_sha read_only
    # An invocation-only XDG_CONFIG_HOME may not be in the running user
    # manager's search path. This conventional directory is stable.
    unit_dir=$(unit_directory) || return 1
    unit_file="$unit_dir/$unit"
    mkdir -p -- "$unit_dir" || return 1
    source="$remote:${SUBDIR#/}"
    mountpoint=$(mountpoint_for "$unit") || return 1
    cache_dir="$(cache_root)/${unit%.service}"
    config_sha=$(config_digest) || return 1
    if [ "${READ_ONLY:-0}" -eq 1 ]; then
        read_only=true
    else
        read_only=false
    fi
    rclone_exec=$(escape_systemd_exec_value "$RCLONE_BIN") || return 1
    config_exec=$(escape_systemd_exec_value "$CONFIG_PATH") || return 1
    source_exec=$(escape_systemd_exec_value "$source") || return 1
    mount_exec=$(escape_systemd_exec_value "$mountpoint") || return 1
    cache_exec=$(escape_systemd_exec_value "$cache_dir") || return 1
    temporary_unit=$(mktemp "$unit_dir/.${unit}.XXXXXX") || return 1

    if ! cat > "$temporary_unit" <<EOF
# Managed by rclone-mount-service
# Config-SHA256=$config_sha
[Unit]
Description=Rclone remote mount ${unit%.service}
Documentation=man:rclone(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStartPre=/bin/mkdir -p -- "$mount_exec" "$cache_exec"
ExecStart=/usr/bin/env -- "$rclone_exec" mount \\
        --config "$config_exec" \\
        --cache-dir "$cache_exec" \\
        --vfs-cache-mode "${VFS_CACHE_MODE:-full}" \\
        --vfs-cache-max-size "${VFS_CACHE_MAX_SIZE:-1G}" \\
        --read-only=$read_only \\
        --log-level INFO \\
        --umask 077 \\
        -- "$source_exec" "$mount_exec"
Restart=on-failure
RestartSec=1m
TimeoutStopSec=30s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    then
        rm -f -- "$temporary_unit"
        return 1
    fi
    if ! mv -f -- "$temporary_unit" "$unit_file"; then
        rm -f -- "$temporary_unit"
        return 1
    fi
}

write_selected_units() {
    local remote unit failed=0
    for remote in "${SELECTED_REMOTES[@]}"; do
        unit=$(service_unit "$remote") || {
            echo "Error: Failed to calculate a service name for remote '$remote'." >&2
            failed=1
            continue
        }
        if ! write_unit_file "$remote" "$unit"; then
            echo "Error: Failed to write $unit for remote '$remote'." >&2
            failed=1
        fi
    done
    return "$failed"
}

enable_selected_remotes() {
    local remote unit mountpoint failed=0
    systemctl --user daemon-reload || return 1
    for remote in "${SELECTED_REMOTES[@]}"; do
        unit=$(service_unit "$remote") || {
            failed=1
            continue
        }
        mountpoint=$(mountpoint_for "$unit") || {
            failed=1
            continue
        }
        # restart also starts an inactive unit and guarantees that rerunning
        # the installer applies the freshly written service definition.
        if systemctl --user enable "$unit" &&
           systemctl --user restart "$unit" &&
           systemctl --user is-active --quiet "$unit"; then
            printf 'Started %s as %s (mountpoint: %s)\n' \
                "$remote" "$unit" "$mountpoint"
        else
            echo "Error: Failed to enable or start $unit" >&2
            echo "Inspect it with: journalctl --user-unit '$unit' --no-pager" >&2
            failed=1
        fi
    done
    return "$failed"
}

unit_is_expected() {
    local unit=$1 remote expected
    for remote in "${AVAILABLE_REMOTES[@]}"; do
        expected=$(service_unit "$remote") || return 2
        [ "$expected" = "$unit" ] && return 0
    done
    return 1
}

prune_orphaned_units() {
    local unit_dir unit_file unit marker config_line current_config
    local removed=0 failed=0
    unit_dir=$(unit_directory) || return 1
    current_config=$(config_digest) || return 1
    [ -d "$unit_dir" ] || {
        echo "No managed units to prune."
        return 0
    }

    for unit_file in "$unit_dir"/rclone-*.service; do
        [ -f "$unit_file" ] || continue
        {
            IFS= read -r marker
            IFS= read -r config_line
        } < "$unit_file"
        [ "$marker" = '# Managed by rclone-mount-service' ] || continue
        [ "$config_line" = "# Config-SHA256=$current_config" ] || continue
        unit=${unit_file##*/}
        unit_is_expected "$unit"
        case $? in
            0) continue ;;
            1)
                if systemctl --user disable --now "$unit" && rm -- "$unit_file"; then
                    echo "Removed orphaned service: $unit"
                    removed=1
                else
                    echo "Error: Failed to remove orphaned service $unit" >&2
                    failed=1
                fi
                ;;
            *)
                echo "Error: Failed to compare managed service $unit." >&2
                failed=1
                ;;
        esac
    done
    if [ "$removed" -eq 1 ]; then
        systemctl --user daemon-reload || failed=1
    fi
    return "$failed"
}

main() {
    parse_options "$@"
    case $? in
        0) ;;
        2) return 0 ;;
        *) return 1 ;;
    esac
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
    if [ "$PRUNE_ONLY" -eq 1 ]; then
        prune_orphaned_units
        return $?
    fi
    select_remotes "${REMOTE_ARGS[@]}" || return 1
    validate_selection_options || return 1
    check_fuse || return 1
    write_selected_units || return 1
    enable_selected_remotes || return 1

    printf '\033[92mInstallation completed. Selected services are running.\033[0m\n'
    echo "To add additional remotes, run the following command:"
    printf '\033[96mrclone config\033[0m\n'
    echo "Follow the prompts to add a new remote. After adding, run the script again to start the service for the new remote."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
