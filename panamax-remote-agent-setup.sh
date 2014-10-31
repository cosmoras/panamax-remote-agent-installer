#!/bin/bash

DOCUMENTATION_URL="http://panamax.io"
DOCKER_HUB_REPO_URL="https://index.docker.io/v1/repositories"
SEP='|'
KEY_NAME="pmx_remote_agent"
WORK_DIR="$(pwd)"
ENV="${WORK_DIR}/.env"
AGENT_CONFIG="${WORK_DIR}/agent"
PMX_AGENT_KEY_FILE="${AGENT_CONFIG}/panamax_agent_key"
CERT_IMAGE="centurylink/openssl:latest"

ADAPTER_IMAGE_FLEET="centurylink/panamax-fleet-adapter:latest"
ADAPTER_IMAGE_KUBER="centurylink/panamax-kubernetes-adapter:latest"
ADAPTER_CONTAINER_NAME="pmx_adapter"

AGENT_IMAGE="centurylink/panamax-remote-agent:latest"
AGENT_CONTAINER_NAME="pmx_agent"

HOST_PORT=3001

echo_install="init:          First time installing Panamax remote agent! - Downloads and installs panamax remote agent."
echo_restart="restart:       Stops and Starts Panamax remote agent/adapter."
echo_reinstall="reinstall:     Deletes your current panamax remote agent/adapter and reinstalls latest version."
echo_info="info:          Displays version of your panamax agent/adapter."
echo_update="update:        Updates to latest Panamax agent/adapter."
echo_checkUpdate="check:         Checks for available updates for Panamax agent/adapter."
echo_uninstall="delete:        Uninstalls Panamax remote agent/adapter."
echo_help="help:          Show this help"
echo_debug="debug:         Display your current Panamax settings."

function display_logo {
    tput clear
    echo ""
    echo -e "\033[0;31;32m███████╗ ██████╗  █████████╗ ██████╗ \033[0m\033[31;37m ██████████╗ ██████╗  ██╗  ██╗\033[0m"
    echo -e "\033[0;31;32m██╔══██║  ╚═══██╗ ███╗  ███║  ╚═══██╗\033[0m\033[31;37m ██║ ██╔ ██║  ╚═══██╗ ╚██╗██╔╝\033[0m"
    echo -e "\033[0;31;32m██   ██║ ███████║ ███║  ███║ ███████║\033[0m\033[31;37m ██║╚██║ ██║ ███████║  ╚███╔╝ \033[0m"
    echo -e "\033[0;31;32m███████╝ ███████║ ███║  ███║ ███████║\033[0m\033[31;37m ██║╚██║ ██║ ███████║  ██╔██╗ \033[0m"
    echo -e "\033[0;31;32m██║      ███████║ ███║  ███║ ███████║\033[0m\033[31;37m ██║╚██║ ██║ ███████║ ██╔╝ ██╗\033[0m"
    echo -e "\033[0;31;32m╚═╝      ╚══════╝ ╚══╝  ╚══╝ ╚══════╝\033[0m\033[31;37m ╚═╝ ╚═╝ ╚═╝ ╚══════╝ ╚═╝  ╚═╝\033[0m"
    echo ""
    echo -e "CenturyLink Labs - http://www.centurylinklabs.com/\n"
}

function cmd_exists() {
    while [ -n "$1" ]
    do
        if [[ "$1" == "docker" ]]; then
            docker -v | grep -w '1\.[2-9]'  >/dev/null 2>&1 || { echo "docker 1.2 or later is required but not installed. Aborting."; exit 1; }
        else
            command -v "$1" >/dev/null 2>&1 || { echo >&2 " '$1' is required but not installed.  Aborting."; exit 1; }
        fi
        shift
    done
}

function get_latest_tag_for_image {
    local image_name=$(echo $1 | sed s#\:.*##g)
    local image_tags=$(curl --silent $DOCKER_HUB_REPO_URL/$image_name/tags  | grep -o "[0-9]*\.[0-9]*\.[0-9]*"  | awk '{ print $1}')
    local arr2=( $(
    for tag in "${image_tags[@]}"
    do
        echo "$tag" | sed 's/\b\([0-9]\)\b/0\1/g'
    done | sort -r | sed 's/\b0\([0-9]\)/\1/g') )
    echo "${arr2[0]}"
}

function check_update {
    local latest_adapter_version=$(get_latest_tag_for_image ${PMX_ADAPTER_IMAGE_NAME})
    local latest_agent_version=$(get_latest_tag_for_image ${AGENT_IMAGE})
    if [[ "$PMX_ADAPTER_VERSION" != "$latest_adapter_version" || "$PMX_AGENT_VERSION" != "$latest_agent_version" ]]; then
        info
        echo -e "\nLatest Panamax component versions: \nAdapter:$latest_adapter_version \nAgent:$latest_agent_version"
        echo -e "\n*** Panamax is out of date! Please use the download/update option to get the latest. Release notes are available at ($DOCUMENTATION_URL) . ***\n"
    fi
}

function info {
    echo -e "\nLocal Panamax component versions: \nAdapter:$PMX_ADAPTER_VERSION \nAgent:$PMX_AGENT_VERSION\n"
}

function validate_install {
    if [[ $(docker ps -a| grep "${ADAPTER_CONTAINER_NAME}\|${AGENT_CONTAINER_NAME}") == "" ]]; then
        echo -e "\nYou don't have remote agent/adapter installed. Please execute init before using other commands.\n\n"
        exit 1;
    fi
}

function uninstall {
    validate_install
    echo -e "\nDeleting panamax remote agent/adapter containers..."
    docker rm -f ${AGENT_CONTAINER_NAME} ${ADAPTER_CONTAINER_NAME}> /dev/null 2>&1
    echo -e "\nDeleting panamax remote agent/adapter images..."
    docker rmi "${CERT_IMAGE}" "${PMX_ADAPTER_IMAGE_NAME}" "${AGENT_IMAGE}" > /dev/null 2>&1
}

function download_image {
    echo -e "\ndocker pull ${1}"
    $(docker pull "${1}" > /dev/null 2>&1)&
    PID=$!
    while $(kill -n 0 "${PID}" 2> /dev/null)
    do
      echo -n '.'
      sleep 2
    done
    echo ""
}

function set_env_var {
    sed -i "/$1=/d" "${ENV}"
    echo $1=$2 >> "${ENV}"
}

function install_adapter {
    echo -e "\nInstalling Panamax adapter:"
    echo -e "\nSelect the ochestrator you want to use: \n"
    select operation in "Kubernetes" "CoreOS Fleet"; do
    case $operation in
        "Kubernetes") cluster_type=0; break;;
        "CoreOS Fleet") cluster_type=1; break;;
    esac
    done

    echo -e "\n"
    if [[ ${cluster_type} == 0 ]]; then
        adapter_name="Kubernetes"
        adapter_image_name=${ADAPTER_IMAGE_KUBER}

        while [[ "${api_url}" == "" ]]; do
          read -p "Enter the API endpoint to access the ${adapter_name} cluster (e.g: https://10.187.241.100:8080/): " api_url
        done

        read -p "Enter username for ${adapter_name} API:" api_username
        stty -echo
        read -p "Enter password for ${adapter_name} API:" api_password; echo
        stty echo

        adapter_env="-e KUBERNETES_MASTER=\"${api_url}\" -e KUBERNETES_USERNAME=\"${api_username}\" -e KUBERNETES_PASSWORD=\"${api_password}\""
    else
        adapter_name="Fleet"
        adapter_image_name=${ADAPTER_IMAGE_FLEET}

        while [[ "${api_url}" == "" ]]; do
          read -p "Enter the API endpoint to access the ${adapter_name} cluster (e.g: https://10.187.241.100:4001/): " api_url
        done

        adapter_env="-e FLEETCTL_ENDPOINT=\"${api_url}\""
    fi

    echo -e "\nStarting Panamax ${adapter_name} adapter:"
    download_image ${adapter_image_name}
    pmx_adapter_run_command="docker run -d --name ${ADAPTER_CONTAINER_NAME} ${adapter_env} --restart=always ${adapter_image_name}"
    set_env_var "PMX_ADAPTER_RUN_COMMAND" \""$pmx_adapter_run_command"\"
    $pmx_adapter_run_command
    set_env_var PMX_ADAPTER_VERSION \"$(get_latest_tag_for_image ${adapter_image_name})\"
    set_env_var PMX_ADAPTER_IMAGE_NAME $adapter_image_name
}

function install_agent {
    echo -e "\nInstalling Panamax remote agent:"
    mkdir -p ${AGENT_CONFIG}
    while [[ "${common_name}" == "" ]]; do
      read -p "Enter the public hostname (dev.example.com) or IP Address (10.3.4.5) of the agent: " common_name
    done

    read -p "Enter the port to run the agent on (${HOST_PORT}): " host_port
    host_port=${host_port:-$HOST_PORT}

    echo -e "\nGenerating SSL Key"
    download_image ${CERT_IMAGE}
    docker run --rm  -e COMMON_NAME="${common_name}" -e KEY_NAME="${KEY_NAME}" -v "${AGENT_CONFIG}":/certs "${CERT_IMAGE}" > /dev/null 2>&1

    agent_id="$(uuidgen)"
    agent_password="$(uuidgen | base64)"

    echo -e "\nStarting Panamax remote agent:"
    download_image ${AGENT_IMAGE}
    pmx_agent_run_command="docker run -d --name ${AGENT_CONTAINER_NAME} --link ${ADAPTER_CONTAINER_NAME}:adapter -e REMOTE_AGENT_ID=$agent_id -e REMOTE_AGENT_API_KEY=$agent_password  --restart=always -v ${AGENT_CONFIG}:/usr/local/share/certs -p ${host_port}:3000 ${AGENT_IMAGE}"
    set_env_var PMX_AGENT_RUN_COMMAND \""$pmx_agent_run_command"\"
    $pmx_agent_run_command

    public_cert="$(<${AGENT_CONFIG}/${KEY_NAME}.crt)"
    echo "https://${common_name}:${host_port}${SEP}${agent_id}${SEP}${agent_password}${SEP}${public_cert}" | base64 > $PMX_AGENT_KEY_FILE
    print_agent_key
    echo -e "\nRemote Agent/Adapter installation complete!\n\n"
    set_env_var PMX_AGENT_VERSION \"$(get_latest_tag_for_image ${AGENT_IMAGE})\"
}

function install {
    if [[ $(docker ps -a| grep "${ADAPTER_CONTAINER_NAME}\|${AGENT_CONTAINER_NAME}") != "" ]]; then
        echo -e "\nYou already have remote agent/adapter installed. Please reinstall.\n\n"; exit 1;
    fi

    echo -e "\nInstalling panamax remote agent/adapter..."
    install_adapter
    install_agent
    set_env_var PMX_INSTALLER_VERSION \"$(<"$CWD"\.version)\"
}

function stop {
 docker rm -f $AGENT_CONTAINER_NAME $ADAPTER_CONTAINER_NAME
}

function start {
    $PMX_ADAPTER_RUN_COMMAND
    $PMX_AGENT_RUN_COMMAND
}

function restart {
    echo -e "\nRestarting panamax remote agent/adapter..."
    validate_install
    stop
    start
}

function update {
    echo -e "\nUpdating panamax remote agent/adapter..."
    validate_install
    download_image "${PMX_ADAPTER_IMAGE_NAME}"
    download_image "${AGENT_IMAGE}"
    restart
}

function reinstall {
    echo -e "\nReinstalling panamax remote agent/adapter..."
    validate_install
    uninstall
    install "$@"
}

function print_agent_key {
    echo -e "\n============================== START =============================="
    cat $PMX_AGENT_KEY_FILE
    echo "============================== END =============================="
    echo -e "\n\nCopy and paste the above (Not including start/end tags) to your local panamax client to connect to this remote agent.\n"
}

function debug {
    print_agent_key
    cat "$ENV"
}

function show_help {
    echo -e "\n$echo_install\n$echo_restart\n$echo_reinstall\n$echo_info\n$echo_checkUpdate\n$echo_update\n$echo_uninstall\n$echo_help\n"
}

function read_params {
    for i in "$@"
    do
    case $(echo "$i" | tr '[:upper:]' '[:lower:]') in
        install|init)
        operation=install
        ;;
        uninstall|delete)
        operation=uninstall
        ;;
        restart)
        operation=restart
        ;;
        update)
        operation=update
        ;;
        check)
        operation=check
        ;;
        info|--version|-v)
        operation=info
        ;;
        reinstall)
        operation=reinstall
        ;;
        debug)
        operation=debug
        ;;
        --help|-h|help)
        show_help;
        exit 1;
        ;;
        *)
        show_help;
        exit 1;
        ;;
    esac
    done
}

function main {
    display_logo
    [[ $UID -eq 0 ]] || { echo -e "\nPlease execute the installer as root.\n\n"; exit 1; }
    cmd_exists curl uuidgen base64 docker sort
    [[ -f "$ENV" ]] && source "$ENV"

    read_params "$@"

    if [[ $# -gt 0 ]]; then
        case $operation in
            install)   install "$@" || { show_help; exit 1; } ;;
            reinstall)   reinstall "$@" || { show_help; exit 1; } ;;
            restart) restart;;
            check) check_update;;
            info) info;;
            update) update;;
            uninstall) uninstall;;
            help) show_help;;
            debug) debug;;
        esac
    else
        PS3="Please select one of the preceding options: "
        select operation in "$echo_install" "$echo_restart" "$echo_reinstall" "$echo_checkUpdate" "$echo_update" "$echo_uninstall" "$echo_help" "$echo_debug" "quit"; do
        case $operation in
            "$echo_install") install; break;;
            "$echo_reinstall") reinstall; break;;
            "$echo_restart") restart; break;;
            "$echo_checkUpdate") check_update; break;;
            "$echo_info") info; break;;
            "$echo_update")  update; break;;
            "$echo_uninstall") uninstall; break;;
            "$echo_help") show_help; break;;
            "$echo_debug")  debug; break;;
            quit) exit 0; break;;
        esac
        done
    fi
}

main "$@";
