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
    local rc_help
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
    if ! "$RCLONE_BIN" version >/dev/null ||
       ! "$RCLONE_BIN" mount --help >/dev/null; then
        echo "Error: Rclone is not working or does not support mount." >&2
        return 1
    fi
    if ! rc_help=$("$RCLONE_BIN" rc --help 2>/dev/null) ||
       [[ "$rc_help" != *--unix-socket* ]]; then
        echo "Error: Rclone 1.68 or newer with RC Unix socket support is required." >&2
        return 1
    fi
}

usage() {
    cat <<'EOF'
Usage:
  rclone-mount-service.sh [install] [OPTIONS] [REMOTE ...]
  rclone-mount-service.sh configure [OPTIONS] REMOTE
  rclone-mount-service.sh list
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
  --shutdown-timeout DURATION Wait for queued uploads before stopping (default: 30m)
  --prune                     Remove managed units for deleted remotes
  -h, --help                  Show this help

Without REMOTE or --all, an interactive selector is shown. Use -- before a
remote name that begins with a dash. Options are persisted in each generated
service. `configure` makes a single-remote update explicit; omitted options are
reset to their documented defaults. `list` maps remote names to units,
mountpoints and their current state.
EOF
}

parse_options() {
    ACTION=install
    SELECT_ALL=0
    PRUNE_ONLY=0
    MOUNTPOINT=
    MOUNTPOINT_SET=0
    SUBDIR=
    READ_ONLY=0
    VFS_CACHE_MODE=full
    VFS_CACHE_MAX_SIZE=1G
    SHUTDOWN_TIMEOUT=30m
    MOUNT_OPTIONS_SET=0
    REMOTE_ARGS=()

    case "${1-}" in
        install|configure|list)
            ACTION=$1
            shift
            ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                return 2
                ;;
            --all)
                SELECT_ALL=1
                ;;
            --mountpoint|--subdir|--vfs-cache-mode|--vfs-cache-max-size|--shutdown-timeout)
                [ "$#" -ge 2 ] || {
                    echo "Error: $1 requires a value." >&2
                    return 1
                }
                case "$1" in
                    --mountpoint) MOUNTPOINT=$2; MOUNTPOINT_SET=1 ;;
                    --subdir) SUBDIR=$2 ;;
                    --vfs-cache-mode) VFS_CACHE_MODE=$2 ;;
                    --vfs-cache-max-size) VFS_CACHE_MAX_SIZE=$2 ;;
                    --shutdown-timeout) SHUTDOWN_TIMEOUT=$2 ;;
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
    if [[ ! "$SHUTDOWN_TIMEOUT" =~ ^[1-9][0-9]*(ms|s|m|h|d)$ ]]; then
        echo "Error: --shutdown-timeout must be a positive duration such as 30m or 2h." >&2
        return 1
    fi
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
    if [ "$ACTION" = list ] &&
       { [ "$SELECT_ALL" -eq 1 ] || [ "${#REMOTE_ARGS[@]}" -gt 0 ] ||
         [ "$PRUNE_ONLY" -eq 1 ] || [ "$MOUNT_OPTIONS_SET" -eq 1 ]; }; then
        echo "Error: list does not accept remote selections or mount options." >&2
        return 1
    fi
    if [ "$MOUNTPOINT_SET" -eq 1 ]; then
        [ -n "$MOUNTPOINT" ] || {
            echo "Error: --mountpoint cannot be empty." >&2
            return 1
        }
        case "$MOUNTPOINT" in
            /*) ;;
            *)
                echo "Error: --mountpoint must be an absolute path." >&2
                return 1
                ;;
        esac
    fi
    case "$MOUNTPOINT$SUBDIR$VFS_CACHE_MAX_SIZE$SHUTDOWN_TIMEOUT" in
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
    if [ "${MOUNTPOINT_SET:-0}" -eq 1 ] && [ "${#SELECTED_REMOTES[@]}" -ne 1 ]; then
        echo "Error: --mountpoint requires exactly one selected remote." >&2
        return 1
    fi
    if [ "${ACTION:-install}" = configure ] &&
       [ "${#SELECTED_REMOTES[@]}" -ne 1 ]; then
        echo "Error: configure requires exactly one remote." >&2
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

escape_systemd_text_value() {
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

mount_digest() {
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
    printf '%s\n' "$digest"
}

mount_storage_id() {
    local digest
    digest=$(mount_digest "$1") || return 1
    printf 'rclone-%s\n' "${digest:0:24}"
}

service_unit() {
    local remote=$1 digest escaped candidate
    local LC_ALL=C
    digest=$(mount_digest "$remote") || return 1
    escaped=$(systemd-escape -- "$remote") || return 1
    candidate="rclone@${escaped}-${digest:0:12}.service"
    if [ "${#candidate}" -le 255 ]; then
        printf '%s\n' "$candidate"
    else
        # systemd-escape can expand a long Unicode name to several times its
        # input length. Keep the exceptional fallback valid and collision-safe.
        printf 'rclone@remote-%s.service\n' "${digest:0:24}"
    fi
}

find_fusermount() {
    local candidate
    for candidate in /usr/bin/fusermount3 /bin/fusermount3 \
                     /usr/bin/fusermount /bin/fusermount; do
        if [ -x "$candidate" ]; then
            FUSERMOUNT_BIN=$candidate
            printf '%s\n' "$candidate"
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
    find_fusermount >/dev/null || return 1
    FINDMNT_BIN=$(type -P findmnt) || {
        echo "Error: findmnt from util-linux is required." >&2
        return 1
    }
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

runtime_root() {
    local root=${XDG_RUNTIME_DIR:-/run/user/$UID}
    case "$root" in
        /*) ;;
        *) root="$PWD/$root" ;;
    esac
    printf '%s/rclone-mount-service\n' "$root"
}

mountpoint_for() {
    local remote=$1 storage_id
    if [ "${MOUNTPOINT_SET:-0}" -eq 1 ]; then
        printf '%s\n' "$MOUNTPOINT"
    else
        storage_id=$(mount_storage_id "$remote") || return 1
        printf '%s/mnt/%s\n' "$HOME" "$storage_id"
    fi
}

write_unit_file() {
    local remote=$1 unit=$2 unit_dir unit_file temporary_unit
    local rclone_exec config_exec source_exec mount_exec cache_exec runtime_exec socket_exec
    local fusermount_exec findmnt_exec stop_exec cleanup_exec timeout_exec device_exec
    local source mountpoint cache_dir runtime_dir rc_socket config_sha read_only storage_id device_name
    local stop_script cleanup_script description_exec
    # An invocation-only XDG_CONFIG_HOME may not be in the running user
    # manager's search path. This conventional directory is stable.
    unit_dir=$(unit_directory) || return 1
    unit_file="$unit_dir/$unit"
    mkdir -p -- "$unit_dir" || return 1
    source="$remote:${SUBDIR#/}"
    storage_id=$(mount_storage_id "$remote") || return 1
    device_name="rclone-mount-service:$storage_id"
    mountpoint=$(mountpoint_for "$remote") || return 1
    cache_dir="$(cache_root)/$storage_id"
    runtime_dir="$(runtime_root)/$storage_id"
    rc_socket="$runtime_dir/rc.sock"
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
    runtime_exec=$(escape_systemd_exec_value "$runtime_dir") || return 1
    socket_exec=$(escape_systemd_exec_value "$rc_socket") || return 1
    if [ -z "${FUSERMOUNT_BIN:-}" ]; then
        find_fusermount >/dev/null || return 1
    fi
    if [ -z "${FINDMNT_BIN:-}" ]; then
        FINDMNT_BIN=$(type -P findmnt) || return 1
    fi
    fusermount_exec=$(escape_systemd_exec_value "$FUSERMOUNT_BIN") || return 1
    findmnt_exec=$(escape_systemd_exec_value "$FINDMNT_BIN") || return 1
    device_exec=$(escape_systemd_exec_value "$device_name") || return 1
    timeout_exec=$(escape_systemd_exec_value "${SHUTDOWN_TIMEOUT:-30m}") || return 1
    description_exec=$(escape_systemd_text_value "$source") || return 1
    # Expanded later by the bash process started from the generated unit.
    # shellcheck disable=SC2016
    stop_script='empty=0; drained=0; while queue=$("$1" rc --unix-socket "$2" vfs/queue 2>/dev/null); do if [[ $queue == *'"'"'"name"'"'"'* ]]; then empty=0; else ((empty += 1)); if (( empty >= 2 )); then drained=1; break; fi; fi; sleep 1; done; (( drained == 1 )) || echo "Warning: unable to confirm an empty Rclone VFS upload queue; cached writes will resume on the next start." >&2; if [[ $3 =~ ^[1-9][0-9]*$ ]]; then kill -TERM "$3" 2>/dev/null || true; fi'
    # A foreground Rclone normally unmounts on SIGTERM. If it exits without
    # detaching FUSE (for example a busy or wedged mount), try a normal unmount
    # and finally a lazy detach so a dead mount is not left behind.
    # shellcheck disable=SC2016
    cleanup_script='source=$("$1" --noheadings --raw --output SOURCE --mountpoint "$2" 2>/dev/null) || exit 0; if [[ $source == "$3" ]]; then "$4" -u "$2" || "$4" -uz "$2"; else echo "Warning: refusing to unmount $2 because it is owned by ${source:-an unknown filesystem}." >&2; fi'
    stop_exec=$(escape_systemd_exec_value "$stop_script") || return 1
    cleanup_exec=$(escape_systemd_exec_value "$cleanup_script") || return 1
    temporary_unit=$(mktemp "$unit_dir/.rclone-mount-service.XXXXXX") || return 1

    if ! cat > "$temporary_unit" <<EOF
# Managed by rclone-mount-service
# Config-SHA256=$config_sha
# Mountpoint=$mountpoint
[Unit]
Description="Rclone mount $description_exec"
Documentation=man:rclone(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStartPre=/bin/mkdir -p -- "$mount_exec" "$cache_exec" "$runtime_exec"
ExecStartPre=/bin/rm -f -- "$socket_exec"
ExecStart=/usr/bin/env -- "$rclone_exec" mount \\
        --config "$config_exec" \\
        --cache-dir "$cache_exec" \\
        --devname "$device_exec" \\
        --rc \\
        --rc-addr "unix://$socket_exec" \\
        --vfs-cache-mode "${VFS_CACHE_MODE:-full}" \\
        --vfs-cache-max-size "${VFS_CACHE_MAX_SIZE:-1G}" \\
        --read-only=$read_only \\
        --log-level INFO \\
        --umask 077 \\
        -- "$source_exec" "$mount_exec"
ExecStop=/bin/bash -c "$stop_exec" -- "$rclone_exec" "$socket_exec" "\$MAINPID"
ExecStopPost=/bin/bash -c "$cleanup_exec" -- "$findmnt_exec" "$mount_exec" "$device_exec" "$fusermount_exec"
KillSignal=SIGTERM
Restart=on-failure
RestartSec=1m
TimeoutStopSec=$timeout_exec
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
        mountpoint=$(mountpoint_for "$remote") || {
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

unit_mountpoint() {
    local unit=$1 remote=$2 unit_file value
    unit_file="$(unit_directory)/$unit"
    if [ -r "$unit_file" ]; then
        value=$(sed -n 's/^# Mountpoint=//p' "$unit_file" | head -n 1)
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi
    mountpoint_for "$remote"
}

list_mounts() {
    local remote unit unit_file state mountpoint
    printf 'REMOTE\tUNIT\tSTATE\tMOUNTPOINT\n'
    for remote in "${AVAILABLE_REMOTES[@]}"; do
        unit=$(service_unit "$remote") || return 1
        unit_file="$(unit_directory)/$unit"
        if [ -f "$(unit_directory)/$unit" ]; then
            state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
            [ -n "$state" ] || state=unknown
        else
            state=not-installed
        fi
        mountpoint=$(unit_mountpoint "$unit" "$remote") || return 1
        printf '%s:\t%s\t%s\t%s\n' "$remote" "$unit" "$state" "$mountpoint"
    done
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

    for unit_file in "$unit_dir"/rclone-*.service "$unit_dir"/rclone@*.service; do
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
    command -v systemd-escape >/dev/null || {
        echo "Error: systemd-escape is required." >&2
        return 1
    }
    if [ "$ACTION" = list ]; then
        list_mounts
        return $?
    fi
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
