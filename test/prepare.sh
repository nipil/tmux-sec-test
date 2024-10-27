#!/bin/bash

# const
BASE_DIR=/tmp/tmux_test
MODES="711 700"
SOCK_NAME="this is a socket"

if [[ $UID -ne 0 ]]
then
    echo "Should be run as root"
    exit 1
fi

function line() {
    echo "============================================================================="
}

function log() {
    line
    echo -e "= $1"
    line
}

log "Install prerequisites"
apt-get update
apt-get install -y sudo tmux

log "tmux version"
TMUX_VER=$(tmux -V)
echo ${TMUX_VER}

log "Creating groups and users"
groupadd tmux_users
for U in tmux_bad tmux_good tmux_other
do
    useradd -m -s /bin/bash -g tmux_users ${U}
done

log "Checking good user umask"
sudo -u tmux_good bash -c umask

log "Cleaning up previous runs"
pkill tmux
rm -Rf ${BASE_DIR}

for M in ${MODES}
do
    log "Creating folder ${P} with permission ${M}"
    P=${BASE_DIR}/good_${M}
    mkdir -p ${P}
    chmod ${M} ${P}
    chown tmux_good:tmux_users ${P}

    # alternate between relative socket path and absolute
    RELATIVE=0
    if [[ "${RELATIVE}" -eq 0 ]]
    then
        S="good_${M}/${SOCK_NAME}"
    else
        S="${BASE_DIR}/good_${M}/${SOCK_NAME}"
    fi
    RELATIVE=$((1 - ${RELATIVE}))

    # create the tmux session attached to the given socket
    cd "${BASE_DIR}"
    sudo -u tmux_good tmux -S "${S}" new-session -d -s sess_name_${M} -n win_name_${M} bash
    echo "tmux created a socket with permissions $(stat --format '%a' "${S}")"

    # pour voir si group ou nobody peut faire quelque chose
    chmod 622 "${S}"
    echo "patched permissions to $(stat --format '%a' "${S}") so that group and nobody may trigger an action"

    # configure le serveur-access pour tester les droits applicatifs et n'autorise pas tmux_other
    # pour vérifier que tmux_other est bloqué même si les perms sockets autorise group à write socket
    if [[ "${TMUX_VER}" > "3.3" ]]
    then
        sudo -u tmux_good tmux -S "${S}" server-access -a -r tmux_bad
        sudo -u tmux_good tmux -S "${S}" server-access -a -r nobody
        echo "Setup read-only server-access for bad and nobody, so that they trigger an action"
    fi
done

# display preparation result
log "Summary of the created socket permissions"
find "${BASE_DIR}" -ls

# probe
for M in ${MODES}
do
    log "Probing for mode ${M}"
    S="${BASE_DIR}/good_${M}/${SOCK_NAME}"
    for U in tmux_bad tmux_other nobody 
    do
        STDERR=$(mktemp)

        ## 3.3+ list-client
        ## when socket IS reachable through filesystem
        ## with tmux_bad as read-only and nobody not in server-access,
        # /tmp/tmux_test/good_711/socket tmux_bad
        # returncode 0
        # /tmp/tmux_test/good_711/socket nobody :
        # access not allowed
        # returncode 0
        ## "access not allowed" is on STDERR

        ## any version list-client
        ## when socket is not reachable:
        # error connecting to /tmp/tmux_test/good_700/socket (Permission denied)
        # returncode 1
        # /tmp/tmux_test/good_700/socket nobody
        # error connecting to /tmp/tmux_test/good_700/socket (Permission denied)
        # returncode 1
       
        sudo -u ${U} tmux -S "${S}" list-client 2>${STDERR} 1>/dev/null
        RESULT=$?
        ERR="$(cat ${STDERR})"
        rm -f "${STDERR}"
        if [[ ${RESULT} -eq 0 ]] && [[ "${ERR}" != "access not allowed" ]]
        then
            echo "UNSAFE ${U} '${S}'"
        else
            echo "SAFE ${U} '${S}': ${ERR}"
        fi
    done
done

log "User interaction required:\n= open other shells, one per command below\n= in 3.3+, only the first one isn't read-only\n= then run secure.sh from the main shell"
echo "sudo -u tmux_good tmux -S '/tmp/tmux_test/good_711/${SOCK_NAME}' attach-session"
echo "sudo -u tmux_bad tmux -S '/tmp/tmux_test/good_711/${SOCK_NAME}' attach-session"
echo "sudo -u nobody tmux -S '/tmp/tmux_test/good_711/${SOCK_NAME}' attach-session"
