#!/bin/bash

BIN_PATH="celestia-appd"
DENOM="utia"
CHAINID="mocha-3"
RPC_ADDR="https://rpc-mocha.pops.one:443"

APP_VERSION="1.0.0-rc9"
APP_GIT_TAG="v1.0.0-rc9"
REQUIRED_TOOLS=("git" "jq" "go" "curl")

FAUCET_HOME_DIR="./faucet"
AMOUNT_FUND_MULTISIG_ACCOUNT=10000000

# The fist number is the Total keys and the second number is Threshold
# We can add as many as we want
# The script tests all possible combinations of the keys
MULTISIG_TEST_PARAMS=(
    "7 5"
    "3 2"
    "3 1"
    "4 4"
)
