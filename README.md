# Onchain Multisig test script

This script carries out a number of tests on multisig accounts.
It accepts a number of settings for multiple `total_keys` and `threshold` and performs a multisig test on all possible combinations of the setting.

Note: Before running the script, make sure to set the necessary variables in the `config.sh` file.

Once the config is set, run the `start.sh`:

```bash
bash start.sh
```

## What steps the script follows

* The script checks for the required tools and exits if any of them are missing.

* The script checks the app binary existence and its version. If the binary is not found or the version does not match the expected version, it will be installed.

* It create a an account called `faucet` if it doesn't exist already. The faucet is used to fund other accounts and it has to be funded from the testnet's faucet. The amount of fund depends on how many tests you wanna run.

* It creates multiple keys by specifying the total number of keys and the threshold. The keys are created and added to each home directory which is created in `/tmp` directory.

* It exchanges public keys between the keys to enable multisig transactions. The script iterates through each key and adds the public keys of other keys to it.

* It generates combinations of keys for multisig transactions. It generates all possible combinations of keys based on the specified threshold.

* It tests multisig transactions by signing and broadcasting transactions using the generated key combinations. The script prepares unsigned transactions, signs them with individual keys, and then signs them with the multisig key. The signed transactions are then broadcasted to the chain.

* The above steps are repeated for multiple test parameters specified in the `MULTISIG_TEST_PARAMS` array.
