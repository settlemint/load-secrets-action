#!/bin/bash
# shellcheck disable=SC2046,SC2001,SC2086
set -e

# Pass User-Agent Inforomation to the 1Password CLI
export OP_INTEGRATION_NAME="1Password GitHub Action"
export OP_INTEGRATION_ID="GHA"
export OP_INTEGRATION_BUILDNUMBER="1010001"

readonly CONNECT="CONNECT"
readonly SERVICE_ACCOUNT="SERVICE_ACCOUNT"

auth_type=$CONNECT
managed_variables_var="OP_MANAGED_VARIABLES"
IFS=','

if [[ "$OP_CONNECT_HOST" != "http://"* ]] && [[ "$OP_CONNECT_HOST" != "https://"* ]]; then
  export OP_CONNECT_HOST="http://"$OP_CONNECT_HOST
fi

# Unset all secrets managed by 1Password if `unset-previous` is set.
unset_prev_secrets() {
  if [ "$INPUT_UNSET_PREVIOUS" == "true" ]; then
    echo "Unsetting previous values..."

    # Find environment variables that are managed by 1Password.
    for env_var in "${managed_variables[@]}"; do
      echo "Unsetting $env_var"
      unset $env_var

      echo "$env_var=" >> $GITHUB_ENV

      # Keep the masks, just in case.
    done

    managed_variables=()
  fi
}

# Install op-cli
install_op_cli() {
  OP_INSTALL_DIR="$(mktemp -d)"
  if [[ ! -d "$OP_INSTALL_DIR" ]]; then
    echo "Install dir $OP_INSTALL_DIR not found"
    exit 1
  fi
  export OP_INSTALL_DIR
  echo "::debug::OP_INSTALL_DIR: ${OP_INSTALL_DIR}"
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    ARCHITECTURE=""
    if [[ "$(uname -m)" == "x86_64" ]]; then
      ARCHITECTURE="amd64"
    elif [[ "$(uname -m)" == "aarch64" ]]; then
      ARCHITECTURE="arm64"
    else
      echo "Unsupported architecture"
      exit 1
    fi
    curl -sSfLo op.zip "https://cache.agilebits.com/dist/1P/op2/pkg/v2.18.0/op_linux_${ARCHITECTURE}_v2.18.0.zip"
    unzip -od "$OP_INSTALL_DIR" op.zip && rm op.zip
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    curl -sSfLo op.pkg "https://cache.agilebits.com/dist/1P/op2/pkg/v2.18.0/op_apple_universal_v2.18.0.pkg"
    pkgutil --expand op.pkg temp-pkg
    tar -xvf temp-pkg/op.pkg/Payload -C "$OP_INSTALL_DIR"
    rm -rf temp-pkg && rm op.pkg
  fi
}

# Uninstall op-cli
uninstall_op_cli() {
  if [[ -d "$OP_INSTALL_DIR" ]]; then
    rm -fr "$OP_INSTALL_DIR"
  fi
}

populating_secret() {
  ref=$(printenv $1)

  echo "Populating variable: $1"
  secret_value=$("${OP_INSTALL_DIR}/op" read "$ref")

  if [ -z "$secret_value" ]; then
    echo "Could not find or access secret $ref"
    exit 1
  fi

  # Register a mask for the secret to prevent accidental log exposure.
  # To support multiline secrets, escape percent signs and add a mask per line.
  escaped_mask_value=$(echo "$secret_value" | sed -e 's/%/%25/g')
  IFS=$'\n'
  for line in $escaped_mask_value; do
    if [ "${#line}" -lt 3 ]; then
      # To avoid false positives and unreadable logs, omit mask for lines that are too short.
      continue
    fi
    echo "::add-mask::$line"
  done
  unset IFS

  if [ "$INPUT_EXPORT_ENV" == "true" ]; then
    # To support multiline secrets, we'll use the heredoc syntax to populate the environment variables.
    # As the heredoc identifier, we'll use a randomly generated 64-character string,
    # so that collisions are practically impossible.
    random_heredoc_identifier=$(openssl rand -hex 32)

    {
      # Populate env var, using heredoc syntax with generated identifier
      echo "$env_var<<${random_heredoc_identifier}"
      echo "$secret_value"
      echo "${random_heredoc_identifier}"
    } >> $GITHUB_ENV
    echo "GITHUB_ENV: $(cat $GITHUB_ENV)"

  else
    # Prepare the secret_value to be outputed properly (especially multiline secrets)
    secret_value=$(echo "$secret_value" | awk -v ORS='%0A' '1')

    echo "::set-output name=$env_var::$secret_value"
  fi

  managed_variables+=("$env_var")
}

# Load environment variables using op cli. Iterate over them to find 1Password references, load the secret values,
# and make them available as environment variables in the next steps.
extract_secrets() {
  IFS=$'\n'
  for env_var in $("${OP_INSTALL_DIR}/op" env ls); do
    populating_secret $env_var
  done
}

read -r -a managed_variables <<< "$(printenv $managed_variables_var)"

if [ -z "$OP_CONNECT_TOKEN" ] || [ -z "$OP_CONNECT_HOST" ]; then
  if [ -z "$OP_SERVICE_ACCOUNT_TOKEN" ]; then
    echo "(\$OP_CONNECT_TOKEN and \$OP_CONNECT_HOST) or \$OP_SERVICE_ACCOUNT_TOKEN must be set"
    exit 1
  fi

  auth_type=$SERVICE_ACCOUNT
fi

printf "Authenticated with %s \n" $auth_type

unset_prev_secrets
install_op_cli
extract_secrets
uninstall_op_cli

unset IFS
# Add extra env var that lists which secrets are managed by 1Password so that in a later step
# these can be unset again.
managed_variables_str=$(IFS=','; echo "${managed_variables[*]}")
echo "$managed_variables_var=$managed_variables_str" >> $GITHUB_ENV
