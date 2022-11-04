#!/bin/bash

# Check if portworx helm charts are installed and the chart status
# helm history portworx (Find the status etc)

# if installed, then check if the version is lower than the one asked
# Check if the version is greater or not

# Wait for the pods to be restarted
function version { echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'; }

# TODO: Parameterise $NAMESPACE
NAMESPACE="kube-system"
PX_CLUSTER_NAME=$3
IMAGE_VERSION=$1
UPGRADE_REQUESTED=$2
SLEEP_TIME=30

DIVIDER="\n*************************************************************************\n"
HEADER="$DIVIDER*\t\tUpgrade Requested to Portworx Enterprise ${IMAGE_VERSION}\t\t*$DIVIDER"

DESIRED=0
READY=0
JSON=0
if $UPGRADE_REQUESTED
then
    printf "Upgrade Requested, Setting up Environment!!\n"
else
    printf "No Upgrade Requested!!\n"
    exit 0
fi

# Install helm3
# Check the Helm Chart Summary
echo "[INFO] Kube Config Path: $CONFIGPATH"
export KUBECONFIG=$CONFIGPATH
kubectl config current-context

CMD="helm"
VERSION=$($CMD version | grep v3)
if [ "$VERSION" == "" ]; then
    echo "[WARN] Helm v3 is not installed, migrating to v3.3.0..."
    mkdir /tmp/helm3
    wget https://get.helm.sh/helm-v3.3.0-linux-amd64.tar.gz -O /tmp/helm3/helm-v3.3.0-linux-amd64.tar.gz
    tar -xzf /tmp/helm3/helm-v3.3.0-linux-amd64.tar.gz -C /tmp/helm3/
    CMD="/tmp/helm3/linux-amd64/helm"
    $CMD version
fi
# Get the Helm status
if ! JSON=$(helm history portworx -n ${NAMESPACE} -o json | jq '. | last'); then
    printf "[ERROR] Helm couldn't find Portworx Installation, will not proceed with the upgrade!! Please install portworx and then try to upgrade.\n"
    exit 1
else
    printf "$HEADER*\t\t\t\tHelm Chart Summary\t\t\t*$DIVIDER\n$JSON$DIVIDER"
fi

#Version Validation
printf "[INFO] Validating if upgrade is possible...\n"
CURRENT_VER=$(kubectl get storagecluster ${PX_CLUSTER_NAME} -n ${NAMESPACE} -o jsonpath={{.items[*].status.version})
printf "$DIVIDER*\t\t\tUpgrade Version Validation\t\t\t$DIVIDER* Requested upgrade from [ $CURRENT_VER ] to [ $IMAGE_VERSION ]\t"

if [[ ! -z "$CURRENT_VER" ]] && [ $(version $IMAGE_VERSION) -ge $(version $CURRENT_VER) ]; then
    printf "[CHECK PASSED]\t*$DIVIDER"
else
    printf "[CHECK FAILED]\t*$DIVIDER"
    printf "[ERROR] Downgrade not supported. Not Upgrading\n"
    exit 1
fi


# Check if portworx ds is there, if there,  get the ds details else, exit with error
# Store the number of desired and ready pods
# Show the current pods and ds status
printf "[INFO] Validating Portworx Cluster Status...\n"
if ! sc_state=$(kubectl get storagecluster ${PX_CLUSTER_NAME} -n ${NAMESPACE}); then
    printf "[ERROR] Portworx Storage Cluster Not Found, will not proceed with the upgrade!! Please install Portworx Enterprise and then try to upgrade.\n"
    exit 1
else
    STATUS=$(kubectl get storagecluster ${PX_CLUSTER_NAME} -n ${NAMESPACE} -o jsonpath='{.items[*].status.phase}')
    if [ "$STATUS" != "Online" ]; then
        printf "[ERROR] Portworx Storage Cluster is not Online. Cluster Status: ($STATUS), will not proceed with the upgrade!!\n"
        exit 1
    else
        state=$(kubectl get storagecluster ${PX_CLUSTER_NAME} -n ${NAMESPACE} -o jsonpath='{.items[*].status}')
        printf "[CHECK PASSED] Portworx Storage Cluster is Online.\n$state\n"
    fi
fi



# Configure kubeconfig
# Get helm binary over the internet, install helm v3.3.0
# Trigger the helm upgrade
printf "[INFO] Installing new Helm Charts...\n"
$CMD repo add ibm-helm https://raw.githubusercontent.com/portworx/ibm-helm/master/repo/stable
$CMD repo update
$CMD get values portworx -n default > /tmp/values.yaml
sed -i -E -e 's@PX_IMAGE=icr.io/ext/portworx/px-enterprise:.*$@PX_IMAGE=icr.io/ext/portworx/px-enterprise:'"$IMAGE_VERSION"'@g' /tmp/values.yaml
$CMD upgrade portworx ibm-helm/portworx -f /tmp/values.yaml --set imageVersion=$IMAGE_VERSION

if [[ $? -eq 0 ]]; then
    echo "[INFO] Upgrade Triggered Succesfully, will monitor the storage cluster!!"
else
    echo "[ERROR] Failed to Upgrade!!"
    exit 1
fi

STATUS=""
LIMIT=10
RETRIES=0
sleep 120

while [ "$RETRIES" -le "$LIMIT" ]
do
    STATUS=$(kubectl get storagecluster ${PX_CLUSTER_NAME} -n ${NAMESPACE} -o jsonpath='{.items[*].status.phase}')
    if [ "$STATUS" == "Online" ]; then
        CLUSTER_ID=$(kubectl get storagecluster ${PX_CLUSTER_NAME} -n ${NAMESPACE} -o jsonpath='{.items[*].status.clusterUid}')
        printf "[SUCCESS] Portworx Storage Cluster is Online. Cluster ID: ($CLUSTER_ID)\n"
        break
    fi
    printf "[INFO] Portworx Storage Cluster Status: [ $STATUS ]\n"
    printf "[INFO] Waiting for Portworx Storage Cluster. (Retry in $SLEEP_TIME secs)\n"
    ((RETRIES++))
    sleep $SLEEP_TIME
done

if [ "$RETRIES" -gt "$LIMIT" ]; then
    printf "[ERROR] All Retries Exhausted!\n"
    exit 1
fi