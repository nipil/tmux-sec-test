#!/bin/bash

function to_stderr() {
    echo "$*" 1>&2
}

if [[ $UID -ne 0 ]]
then
    to_stderr "Should be run as root"
    exit 1
fi

while [[ $# -ne 0 ]]
do
    [[ "$1" == "--debug" ]] && DEBUG=1
    [[ "$1" == "--dry-run" ]] && DRY_RUN=1
    shift
done

function log_debug() {
    [[ -n "${DEBUG}" ]] && to_stderr "DEBUG: $*"
}

function log_info() {
    echo "INFO: $*"
}

function log_warning() {
    echo "WARNING: $*"
}

function log_error() {
    echo "ERROR: $*"
}

function has_tmux() {
    tmux -V 1>/dev/null 2>/dev/null
}

function tmux_version_has_server_access() {
    local REQ_VER="3.3"
    local CUR_VER=$(tmux -V)
    local OLD_VER=$(echo -e "${CUR_VER}\ntmux ${REQ_VER}" | sort | head -n 1)
    test "${OLD_VER}" == "tmux ${REQ_VER}"
}

function tmux_pid_recreate_socket() {
    local PID="$1" SIG="USR1"
    # asks to recreate socket by sending SIGUSR1 (and it wipes changed permissions)
    log_debug "Send ${SIG} signal to process ${PID}"
    kill -"${SIG}" "${PID}"
}

function tmux_socket_get_pid() {
    local SOCK="$1" PID
    tmux -S "${SOCK}" display-message -p "#{pid}"
}

function tmux_socket_server_access_list() {
    local USP="$1"
    # Sample:
    # tmux_good (W)
    # nobody (R)
    tmux -S "${USP}" server-access -l
}

function tmux_socket_server_access_deny_user() {
    local USP="$1" USR="$2"
    tmux -S "${USP}" server-access -d "${USR}"
}

function tmux_socket_list_clients() {
    local USP="$1"
    # Sample :
    # /dev/pts/3 12360
    # /dev/pts/5 12468
    # /dev/pts/4 12741
    tmux -S "${USP}" list-clients -F "#{client_name} #{client_pid}"
}

function tmux_socket_detach_client() {
    local USP="$1" CLIENT="$2"
    tmux -S "${USP}" detach-client -t "${CLIENT}"
}

function get_process_owner() {
    local PID="$1"
    # https://man7.org/linux/man-pages/man5/proc_pid_status.5.html
    # https://en.wikipedia.org/wiki/User_identifier
    # Sample:
    # Uid: real, effective, saved set, filesystem
    grep '^Uid:' /proc/"${PID}"/status \
    | awk '{ print $2 }' \
    | xargs id -n -u
}

function get_unix_socket_inode_path() {
    local INODE="${1}"
    # Sample:
    # Num       RefCount Protocol Flags    Type St Inode Path
    # 00000000f886be50: 00000002 00000000 00010000 0001 01 1087662 good_777/this is a socket
    # 00000000ea26d66c: 00000002 00000000 00010000 0001 01 965695 /tmp/vscode-remote-containers-ipc-a3fc17c3-090c-47d9-9831-ef6f0d5ade22.sock
    # 0000000099f2ca14: 00000003 00000000 00000000 0001 03 968718
    # 00000000af213711: 00000002 00000000 00010000 0001 01 965696 /tmp/vscode-ssh-auth-a3fc17c3-090c-47d9-9831-ef6f0d5ade22.sock
    # 00000000d4145f8a: 00000003 00000000 00000000 0001 03 968708
    # 000000003f160eea: 00000002 00000000 00010000 0001 01 965697 /root/.gnupg/S.gpg-agent
    cat /proc/net/unix \
    | awk '$7 == "'"${INODE}"'" { print substr($0, index($0, $7) + length($7) + 1) }' \
    | grep -v '^[[:space:]]*$'
}

function get_process_socket_inodes() {
    local PID="$1"
    # Sample: find
    # /proc/self/fd/0
    #
    # Sample: readlink
    # /dev/null
    # pipe:[2341472]
    # socket:[2341473]
    # /dev/pts/ptmx
    #
    find /proc/"${PID}"/fd -maxdepth 1 -type l -print0 \
    | xargs -0 readlink \
    | grep ^socket \
    | grep -oP '\d+' 
}

function get_process_cwd() {
    local PID="$1"
    readlink /proc/"${PID}"/cwd
}

function get_unix_socket_path_from_inodes() {
    # TODO(enhancement): search all inodes in a single pass
    local CWD="$1" INODE
    while read -r INODE
    do
        log_debug "Found process socket inode: ${INODE}"
        get_unix_socket_inode_path "${INODE}" 
    done
}

function prepend_cwd_if_relative() {
    local CWD="${1}"
    while read -r USP
    do
        if [[ ! "${USP}" == /* ]]
        then
            USP="${CWD}/${USP}"
        fi
        log_debug "Found unix socket path: ${USP}"
        echo "${USP}"
    done
}

function get_unix_socket_from_pids() {
    local PID CWD
    while read -r PID
    do
        tmux_pid_recreate_socket "${PID}"
        CWD=$(get_process_cwd "${PID}")
        log_debug "Found process id ${PID} with working directory '${CWD}'"
        get_process_socket_inodes "${PID}" \
        | get_unix_socket_path_from_inodes "${PID}" \
        | prepend_cwd_if_relative "${CWD}"
    done
}

function get_all_tmux_pids() {
    pgrep tmux
}

function server_deny_non_owner() {
    local USP="$1" OWNER="$2" USR
    # early return if version does not support 'server-access' command
    tmux_version_has_server_access || return 1
    # remove any user 
    tmux_socket_server_access_list "${USP}" \
    | awk '{ print $1 }' \
    | grep -v "^${OWNER}\b" \
    | while read -r USR
        do
            log_warning "Denying non-owner user ${USR} from accessing ${OWNER} owned tmux server at socket: ${USP}"
            [[ -n "${DRY_RUN}" ]] && { log_info "dry-run, skipping action"; continue; }
            tmux_socket_server_access_deny_user "${USP}" "${USR}" \
            && log_info "Successfully disabled ${USR} from socket: ${USP}" \
            || log_error "Could not disable server-access ${USR} from socket: ${USP}"
        done
}

function server_detach_all_clients_not_owner() {
    local USP="$1" OWNER="$2" USR PID CLIENT
    tmux_socket_list_clients "${USP}" \
    | while read -r CLIENT PID
        do
            USR=$(get_process_owner ${PID})
            log_debug "Found client ${CLIENT} with pid ${PID} owned by user ${USR} for socket: ${USP}"
            [[ "${USR}" == "${OWNER}" ]] && { log_debug "Skipping owner client ${CLIENT}"; continue; }
            log_warning "Detaching non-owner client ${CLIENT} of user ${USR} from ${OWNER} owned tmux server at socket: ${USP}"
            [[ -n "${DRY_RUN}" ]] && { log_info "dry-run, skipping action"; continue; }
            tmux_socket_detach_client "${USP}" "${CLIENT}" \
            && log_info "Successfully detached ${CLIENT} from socket: ${USP}" \
            || log_error "Could not detach client ${CLIENT} from socket: ${USP}"
        done
}

function fix_socket_path_permissions() {
    local USP="$1" SEC_X_GROUP=1 SEC_X_OTHER=1 DIR OPERM
    DIR="${USP}"
    while [[ "${DIR}" != "/" ]]
    do
        DIR=$(dirname "${DIR}")
        OPERM=$(stat --format '%a' "${DIR}")
        log_debug "Folder permissions before securing are ${OPERM} for: ${DIR}"
        # Bash : add 8# prefix for explicit octal
        if [[ ${SEC_X_GROUP} == 1 && $((8#${OPERM} & 8#10)) -eq 0 ]]
        then
            log_debug "Secured 'group' execution permission on ${DIR} protects tmux socket: ${USP}"
            SEC_X_GROUP=0
        fi
        if [[ ${SEC_X_OTHER} -eq 1 && $((8#${OPERM} & 8#1)) -eq 0 ]]
        then
            log_debug "Secured 'other' execution permission on ${DIR} protects tmux socket: ${USP}"
            SEC_X_OTHER=0
        fi
    done
    if [[ ${SEC_X_GROUP} == 1 && ${SEC_X_OTHER} == 1 ]]
    then
        OPERM=$(stat --format '%a' "${USP}")
        log_debug "Socket permissions before securing socket are ${OPERM} for: ${USP}"
        if [[ $((8#${OPERM} & 8#22)) -ne 0 ]]
        then
            log_warning "Need to secure socket permissions, as no 'group' and 'other' folder permissions have been found on the path to tmux socket: ${USP}"
        fi
        if [[ $((8#${OPERM} & 8#20)) -ne 0 ]]
        then
            log_warning "Write permissions for 'group' found on tmux server socket: ${USP}"
            if [[ -n "${DRY_RUN}" ]]
            then
                log_info "dry-run, skipping action"
            else
                chmod g-w "${USP}" \
                && log_info "Removed write permissions for 'group' on: ${USP}" \
                || log_error "Could not remove write permissions for 'group' on: ${USP}"
            fi
        fi
        if [[ $((8#${OPERM} & 8#2)) -ne 0 ]]
        then
            log_warning "Write permissions for 'others' found on tmux server socket: ${USP}"
            if [[ -n "${DRY_RUN}" ]]
            then
                log_info "dry-run, skipping action"
            else
                chmod o-w "${USP}" \
                && log_info "Removed write permissions for 'others' on: ${USP}" \
                || log_error "Could not remove write permissions for 'others' on: ${USP}"
            fi
        fi
        OPERM=$(stat --format '%a' "${USP}")
        log_info "Socket permissions after securing socket are ${OPERM} for: ${USP}"
    fi
}

function process_server_sockets() {
    local USP PID OWNER
    while read -r USP
    do
        log_debug "Processing socket ${USP}"
        PID=$(tmux_socket_get_pid "$USP")
        log_debug "Found server process ${PID} from ${USP}"
        OWNER=$(get_process_owner "${PID}")
        log_debug "Found process owner ${OWNER} for ${PID}"
        server_detach_all_clients_not_owner "${USP}" "${OWNER}"
        server_deny_non_owner "${USP}" "${OWNER}"
        fix_socket_path_permissions "${USP}"
    done
}

function main() {
    if ! has_tmux
    then
        log_error "Tmux not installed. Exiting."
        exit 1
    fi
    get_all_tmux_pids | sort -u -n \
    | get_unix_socket_from_pids | sort -u \
    | process_server_sockets
    log_info "End of script"
}

main
