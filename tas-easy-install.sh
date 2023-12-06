#!/usr/bin/env sh

# Define the maximum number of attempts and the sleep interval (in seconds)
max_attempts=30
sleep_interval=10

# Function to check pod status
check_pod_status() {
    local namespace="$1"
    local pod_name_prefix="$2"
    local attempts=0

    while [[ $attempts -lt $max_attempts ]]; do
        pod_name=$(oc get pod -n "$namespace" | grep "$pod_name_prefix" | grep "Running" | awk '{print $1}')
        if [ -n "$pod_name" ]; then
            pod_status=$(oc get pod -n "$namespace" "$pod_name" -o jsonpath='{.status.phase}')
            if [ "$pod_status" == "Running" ]; then
                echo "$pod_name is up and running in namespace $namespace."
                return 0
            else
                echo "$pod_name is in state: $pod_status. Retrying in $sleep_interval seconds..."
            fi
        else
            echo "No pods with the prefix '$pod_name_prefix' found in namespace $namespace. Retrying in $sleep_interval seconds..."
        fi

        sleep $sleep_interval
        attempts=$((attempts + 1))
    done

    echo "Timed out. No pods with the prefix '$pod_name_prefix' reached the 'Running' state within the specified time."
    return 1
}

# Install SSO Operator and Keycloak service
install_sso_keycloak() {
    oc apply --kustomize keycloak/operator/base
    check_pod_status "keycloak-system" "rhsso-operator"
    # Check the return value from the function
    if [ $? -ne 0 ]; then
        echo "Pod status check failed. Exiting the script."
        exit 1
    fi

    oc apply --kustomize keycloak/resources/base
    check_pod_status "keycloak-system" "keycloak-postgresql"
    # Check the return value from the function
    if [ $? -ne 0 ]; then
        echo "Pod status check failed. Exiting the script."
        exit 1
    fi
}

# Generate the script to initialize the environment variables for the service endpoints
generate_env_script() {
    # Write the script to a file
cat <<EOL > tas-env-variables.sh
#!/bin/bash

export BASE_HOSTNAME=apps.$(oc get dns cluster -o jsonpath='{ .spec.baseDomain }')
echo "base hostname = \$BASE_HOSTNAME"

export KEYCLOAK_REALM=sigstore
export FULCIO_URL=https://fulcio.\$BASE_HOSTNAME
export KEYCLOAK_URL=https://keycloak-keycloak-system.\$BASE_HOSTNAME
export REKOR_URL=https://rekor.\$BASE_HOSTNAME
export TUF_URL=https://tuf.\$BASE_HOSTNAME
export OIDC_ISSUER_URL=\$KEYCLOAK_URL/auth/realms/\$KEYCLOAK_REALM
EOL

    # Make the generated script executable
    chmod +x tas-env-variables.sh
    echo "A script 'tas-env-variables.sh' to set a local signing environment has been created in the current directory."
    echo "To initialize the environment variables, run 'source ./tas-env-variables.sh' from the terminal."
}

# Install Red Hat SSO Operator and setup Keycloak service
install_sso_keycloak

common_name=apps.$(oc get dns cluster -o jsonpath='{ .spec.baseDomain }')

segment_backup_job=$(oc get job -n trusted-artifact-signer-monitoring --ignore-not-found=true | tail -n 1 | awk '{print $1}')
if [[ -n $segment_backup_job ]]; then
    oc delete job $segment_backup_job -n trusted-artifact-signer-monitoring
fi

oc new-project trusted-artifact-signer-monitoring > /dev/null 2>&1


pull_secret_exists=$(oc get secret pull-secret -n trusted-artifact-signer-monitoring --ignore-not-found=true)
if [[ -n $pull_secret_exists ]]; then
    read -p "Secret \"pull-secret\" in namespace \"trusted-artifact-signer-monitoring\" already exists. Overwrite it (Y/N)?: " -n1 overwrite_pull_secret
    echo ""
    if [[ $overwrite_pull_secret == "Y" || $overwrite_pull_secret == 'y' ]]; then
        read -p "Please enter the absolute path to the pull-secret.json file:
" pull_secret_path
        file_exists=$(ls $pull_secret_path 2>/dev/null)
        if [[ -n $file_exists ]]; then
            oc create secret generic pull-secret -n trusted-artifact-signer-monitoring --from-file=$pull_secret_path --dry-run=client -o yaml | oc replace -f -
        else
            echo "pull secret was not found based on the path provided: $pull_secret_path"
            exit 0
        fi
    elif [[ $overwrite_pull_secret == "N" || $overwrite_pull_secret == 'n' ]]; then
        echo "Skipping overwriting pull-secret..."
    else 
        echo "Bad input. Skipping this step, using existing pull-secret"
    fi
else
    read -p "Please enter the absolute path to the pull-secret.json file:
" pull_secret_path
    oc create secret generic pull-secret -n trusted-artifact-signer-monitoring --from-file=$pull_secret_path
fi

oc create ns fulcio-system
oc create ns rekor-system

# TODO: uncomment to install from helm repository, install from the local repo checkout for now
#helm repo add trusted-artifact-signer https://repo-securesign-helm.apps.open-svc-sts.k1wl.p1.openshiftapps.com/helm-charts
#helm repo update
#OPENSHIFT_APPS_SUBDOMAIN=$common_name envsubst < examples/values-sigstore-openshift.yaml | helm install --debug trusted-artifact-signer trusted-artifact-signer/trusted-artifact-signer -n trusted-artifact-signer --create-namespace --values -
OPENSHIFT_APPS_SUBDOMAIN=$common_name envsubst < examples/values-sigstore-openshift.yaml | helm upgrade -i trusted-artifact-signer --debug charts/trusted-artifact-signer  -n trusted-artifact-signer --create-namespace --values -

# Create the script to initialize the environment variables for the service endpoints
generate_env_script

