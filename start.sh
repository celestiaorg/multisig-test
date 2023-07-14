#!/bin/bash
set -o errexit -o nounset

. config.sh

BASE_DIR="."
function reset_base_dir() {
    declare -g BASE_DIR=`mktemp -d`
    echo "BASE_DIR:" ${BASE_DIR}
}

function check_required_tools() {
    printf "Checking required tools..." 
    for t in "${REQUIRED_TOOLS[@]}"
    do
        if ! which "$t" &> /dev/null; then
            echo -e "\n$t is not installed. Please install it."
            exit 1
        fi
    done
    echo "Ok"
}

function install_binary() {
    echo "Installing celestia app binary..."
    rm -rf ./celestia-app
    git clone https://github.com/celestiaorg/celestia-app.git
    cd celestia-app
    git checkout tags/${APP_GIT_TAG} -b ${APP_GIT_TAG}
    make install
    cd ..
    rm -rf ./celestia-app
}

function get_rpc_version() {
    curl -s "${RPC_ADDR}/abci_info" | jq -r '.result.response.version'
}

function init_binary() {
    printf "Checking binary existence..." 
    if ! which "${BIN_PATH}" &> /dev/null; then
        echo -e "\nBinary not found: ${BIN_PATH}"
        install_binary
    fi
    echo "Ok"

    printf "Checking binary version..." 
    if [ `${BIN_PATH} version 2>&1` != "${APP_VERSION}" ]; then
        echo "Binary version not matched. Expected: ${APP_VERSION}, Actual: " `${BIN_PATH} version 2>&1`
        install_binary
    fi
    echo "Ok"
    echo "Current App Version: " `${BIN_PATH} version 2>&1`

    printf "Checking RPC version..."
    RPCVER=`get_rpc_version`
    if [ "${RPCVER}" != "${APP_VERSION}" ]; then
        echo -e "\nRPC version not matched. Expected: ${APP_VERSION}, Actual: ${RPCVER}"
        exit 1
    fi
    echo "Ok"
}

function get_facuet_key_address() {
    ${BIN_PATH} keys show faucet_key --address --keyring-backend=test --home ${FAUCET_HOME_DIR} 2>/dev/null
}

function create_facuet_key() {
    if ! [ -f "${FAUCET_HOME_DIR}/config/genesis.json" ]; then
        ${BIN_PATH} init faucet --chain-id ${CHAINID} --home ${FAUCET_HOME_DIR} >/dev/null 2>&1
    fi
    if [[ `get_facuet_key_address` == "" ]]; then
        ${BIN_PATH} keys add faucet_key --keyring-backend=test --home ${FAUCET_HOME_DIR} >/dev/null 2>&1
    fi
    get_facuet_key_address
}

function create_keys() {
    TOTAL_KEYS="$1"
    MULTISIG_THRESHOLD="$2"

    printf "Creating ${TOTAL_KEYS} keys..."
    for ((i=1; i<=TOTAL_KEYS; i++))
    do
        HOME_DIR=${BASE_DIR}/home${i}
        ${BIN_PATH} init home${i} --chain-id ${CHAINID} --home ${HOME_DIR} >/dev/null 2>&1
        ${BIN_PATH} keys add k${i} --keyring-backend=test --home ${HOME_DIR} >/dev/null 2>&1
    done
    echo "Ok"

    printf "Exchanging public keys..."
    for ((i=1; i<=TOTAL_KEYS; i++))
    do
        HOME_DIR=${BASE_DIR}/home${i}
        KEYS_LIST=""
        for ((j=1; j<=TOTAL_KEYS; j++))
        do
            KEYS_LIST+="k${j},"
            if [ $i -eq $j ]; then
                continue
            fi
            pubkey=`${BIN_PATH} keys show k${j} --pubkey --keyring-backend=test --home ${BASE_DIR}/home${j}`
            ${BIN_PATH} keys add k${j} --pubkey=${pubkey} --keyring-backend=test --home ${HOME_DIR} >/dev/null 2>&1
        done
        KEYS_LIST="${KEYS_LIST%,}" # remove last comma
        ${BIN_PATH} keys add multikey --multisig-threshold ${MULTISIG_THRESHOLD} --multisig ${KEYS_LIST} --keyring-backend=test --home ${HOME_DIR} >/dev/null 2>&1
        # ${BIN_PATH} keys list --keyring-backend=test --home ${HOME_DIR}
    done
    echo "Ok"
}

function get_key_address() {
    KEY_NAME="$1"
    HOME_DIR=${BASE_DIR}/home1
    ${BIN_PATH} keys show ${KEY_NAME} --address --keyring-backend=test --home ${HOME_DIR}
}

function get_multisig_address(){
    get_key_address "multikey"
}

function query_balance() {
    ADDRESS="$1"
    ${BIN_PATH} query bank balances ${ADDRESS} --node ${RPC_ADDR} --output json | jq -r ".balances[] | select(.denom == \"${DENOM}\") | .amount"
}

function fund_address(){
    ADDRESS="$1"
    AMOUNT="$2"
    output=`${BIN_PATH} tx bank send faucet_key ${ADDRESS} ${AMOUNT} \
    --keyring-backend=test --chain-id ${CHAINID} --home ${FAUCET_HOME_DIR} \
    --node ${RPC_ADDR} --yes --broadcast-mode block --fees 210000${DENOM} 2>&1`
    
    if echo "$output" | grep -q "code: 0"; then
        txhash=$(echo "$output" | awk '/txhash:/ {print $2}')
        echo $txhash
    else
        echo "TX failed: $output"
        exit 1
    fi
}

function generate_keys_combinations() {
  local threshold=$1
  shift
  local keys=("$@")

  if (( threshold == 1 )); then
    for key in "${keys[@]}"; do
      echo "$key"
    done
  elif (( threshold > 1 )); then
    local count=${#keys[@]}
    local i=0
    local j=$((i+1))
    while (( i <= count - threshold )); do
      while (( j < count )); do
        local current_key="${keys[i]}"
        local remaining_keys=("${keys[@]:$((i+1))}")
        generate_keys_combinations $((threshold - 1)) "${remaining_keys[@]}" | awk -v key="$current_key" '{print key "," $0}'
        ((j++))
      done
      ((i++))
      j=$((i+1))
    done
  fi
}

function test_multisig_tx(){
    # Get the multisig information
    output=`${BIN_PATH} keys show multikey --keyring-backend=test --home "${BASE_DIR}/home1" --pubkey 2>&1`
    total_keys=$(echo "$output" | jq '.public_keys | length')
    threshold=$(echo "$output" | jq '.threshold')

    echo -e "Total keys: ${total_keys}\tThreshold: ${threshold}\n"

    SHARED_DIR="${BASE_DIR}/shared"
    mkdir -p ${SHARED_DIR}

    keys=()
    for ((i=1; i<=total_keys; i++)); do
        keys+=("k$i")
    done
    keys_combinations=`generate_keys_combinations "$threshold" "${keys[@]}"`

    tx_counter=0
    while IFS= read -r line; do
        printf "Preparing TX for key batch: %s..." "$line"
        multi_addr=`get_multisig_address`
        receiver_addr=`get_key_address "k1"`

        ((tx_counter+=1))
        tx_file="${SHARED_DIR}/unsignedTx_${tx_counter}.json"

        ${BIN_PATH} tx bank send ${multi_addr} ${receiver_addr} 1${DENOM} \
            --keyring-backend=test --home "${BASE_DIR}/home1" \
            --generate-only --fees 210000${DENOM} > "${tx_file}"

        if [ ! -s "${tx_file}" ]; then
            echo -e "\n\tThe TX file \"${tx_file}\" is empty!"
            exit 1
        fi
        echo "OK: ${tx_file}"

        signature_files=""

        IFS=',' read -ra keys_batch <<< "$line"
        for key in "${keys_batch[@]}"; do
            key_number="${key:1}"
            key_addr=`get_key_address "${key}"`

            printf "\tSigning Tx by $key..."
            ${BIN_PATH} tx sign "${tx_file}" --multisig=${multi_addr} --from=${key_addr} \
                --chain-id ${CHAINID} --output-document="${SHARED_DIR}/signature_${tx_counter}_${key}.json" \
                --keyring-backend=test --home "${BASE_DIR}/home${key_number}" --yes --node ${RPC_ADDR}
            if [ $? -eq 0 ]; then
                echo "Ok."
            else
                echo "Signing TX encountered an error."
                exit 1
            fi

            signature_files+=" ${SHARED_DIR}/signature_${tx_counter}_${key}.json"
        done

        printf "\tSigning Tx by multisig key..."
        signed_tx_file="${SHARED_DIR}/signedTx_${tx_counter}.json"
        ${BIN_PATH} tx multisign "${tx_file}" multikey ${signature_files} \
            --chain-id ${CHAINID} --keyring-backend=test --home "${BASE_DIR}/home1" \
            --yes --node ${RPC_ADDR} > "${signed_tx_file}" 2>&1
        if [ $? -eq 0 ]; then
            echo "Ok: ${signed_tx_file}"
        else
            echo "Signing TX encountered an error."
            exit 1
        fi

        printf "Receiver balance before broadcasting Tx:"
        echo `query_balance ${receiver_addr}`
        
        printf "Broadcasting Tx to the chain... "
        output=`${BIN_PATH} tx broadcast ${signed_tx_file} \
            --chain-id ${CHAINID} --broadcast-mode block --yes --node ${RPC_ADDR} 2>&1`
        if echo "$output" | grep -q "code: 0"; then
            txhash=$(echo "$output" | awk '/txhash:/ {print $2}')
            echo "TxHash: $txhash"
        else
            echo "TX failed: $output"
            exit 1
        fi

        printf "Receiver balance after broadcasting Tx:"
        query_balance ${receiver_addr}
        echo ""

    done <<< "$keys_combinations"

}

# ------- main ------- #

check_required_tools
init_binary
FAUCET_ACCOUNT=`create_facuet_key`
echo "Fund the folowing address from faucet: ${FAUCET_ACCOUNT}"
while true; do
    printf "Checking balance..."
    amount=`query_balance ${FAUCET_ACCOUNT}`
    amount=$((amount))
    printf "Ok, balance: ${amount}${DENOM}"
    if ((amount > AMOUNT_FUND_MULTISIG_ACCOUNT)); then
        break
    fi

    printf "\tWaiting..."
    sleep 5
    printf "\r                                                             \r"
done
echo -e "\n"

for test_params in "${MULTISIG_TEST_PARAMS[@]}"; do
    echo -e "\n============================================\n"
    echo -e "testing params: ${test_params}"
    reset_base_dir
    
    # create_keys #total_keys #threshold
    create_keys $test_params

    printf "Funding the multisig acccount..."
    fund_address `get_multisig_address` ${AMOUNT_FUND_MULTISIG_ACCOUNT}${DENOM}
    echo -e "Ok"

    printf "Multisig account balance: "
    query_balance `get_multisig_address`
    echo -e "\n"

    test_multisig_tx
done