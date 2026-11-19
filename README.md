# 1pimp

`1pimp` moves selected values from a local `.env` file into a new 1Password item and replaces those values with `op://` secret references.

## Requirements

- Bash
- [1Password CLI (`op`)](https://developer.1password.com/docs/cli/) installed and signed in, with access to a vault where you can create items
- `jq`
- Python 3 (`python3`)

## Usage

Run the script from the directory containing the `.env` file. Pass the names of the keys to move, or omit them to choose keys in an interactive terminal list (Up/Down to move, Space to select or deselect, Enter to continue):

```sh
bash /path/to/1pimp.sh API_KEY DATABASE_PASSWORD
bash /path/to/1pimp.sh
```

For example, given:

```dotenv
API_KEY=example-api-key
DATABASE_PASSWORD="example-password"
```

If you have multiple signed-in 1Password accounts, the script prompts you to select one (defaulting to your last choice). With one account, it uses that account automatically. It then prompts you to select a vault in that account (defaulting to the last vault you selected, if available) and to name the new item (defaulting to the current directory name). It creates one **API Credential** item with a password field for each requested key, then updates `.env` to contain references such as:

```dotenv
API_KEY="op://My Vault/my-project/API_KEY"
DATABASE_PASSWORD="op://My Vault/my-project/DATABASE_PASSWORD"
```

You can then resolve the references when running your application with 1Password CLI, for example:

```sh
op run --env-file=.env -- your-command
```

The selected account and vault are saved in `${XDG_CONFIG_HOME:-$HOME/.config}/1pimp/config.json` for future runs. To change the default account, choose another account at the prompt; subsequent runs will default to that choice. When resolving references with multiple accounts, specify the account with `op run --account=<account-id> --env-file=.env -- your-command`.

## Important notes

- **The script prints the selected secret values to the terminal** before creating the item. Avoid running it where terminal output is recorded or shared.
- It edits `.env` in place. Keep a backup until you have verified that the new references resolve, and do not commit plaintext secrets to version control.
- Keys must already exist in `.env`; keys whose values begin with `op://` are rejected. If a key appears more than once, the last value is stored in 1Password and every matching line is replaced in `.env`.
- Run it from the directory containing the target `.env` file; the script does not take a path to that file.
