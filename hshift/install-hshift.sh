if [ "$CLUSTER_NAME_HSHIFT" == "" ]; then
  echo "Please provide a unique non-empty CLUSTER_NAME_HSHIFT var."; exit;
fi

# Setup env var for pull secret
export PULL_SECRET=~/Downloads/pull-secret.json 

# Pick a region.
export REGION=us-east-1

CLUSTER_ID_HSHIFT=$(ocm describe cluster $CLUSTER_NAME_HSHIFT | grep -m1 ID: | cut -d ':' -f2 | awk '{print $1, $3}')
echo "Cluster ID: $CLUSTER_ID_HSHIFT" 
# Extract AWS credentials to a file for use in hypershift CLI.
# Uses ~/.aws/ as the base director with the assumption that this is reasonably secure already.
export AWS_CREDS_FILE=~/.aws/credentials
export CLUSTER_AWS_CREDS_FILE=~/.aws/credentials.$CLUSTER_ID_HSHIFT
if [ "$REGION" == "" ]; then
  export REGION="us-east-1"
fi
INFRA_JSON=$(oc get infrastructure cluster -o json)
PLATFORM=$(echo "$INFRA_JSON" | jq -r '.status.platform')
APISERVER=$(echo "$INFRA_JSON" | jq -r '.status.apiServerInternalURI' | grep devshift.org)
INFRA_NAME=$(echo $INFRA_JSON | jq -r '.status.infrastructureName')
INFRA_FOUND=$(grep -c $INFRA_NAME $AWS_CREDS_FILE)
if [ "$PLATFORM" == "AWS" ] && [ "$APISERVER" != "" ]; then
  if [ "$INFRA_FOUND" == "0" ]; then
    echo -e "\nAdding profile '$INFRA_NAME' to creds file '$AWS_CREDS_FILE'."
    cat <<EOF >>$AWS_CREDS_FILE

[$INFRA_NAME]
aws_access_key_id = $(oc -n kube-system get secret aws-creds -o json | jq -r .'data["aws_access_key_id"]' | base64 --decode)
aws_secret_access_key = $(oc -n kube-system get secret aws-creds -o json | jq -r .'data["aws_secret_access_key"]' | base64 --decode)
EOF
  fi
  echo -e "\nCreating AWS creds file with default profile '$CLUSTER_AWS_CREDS_FILE'."
  cat <<EOF >"$CLUSTER_AWS_CREDS_FILE"
[default]
aws_access_key_id = $(oc -n kube-system get secret aws-creds -o json | jq -r .'data["aws_access_key_id"]' | base64 --decode)
aws_secret_access_key = $(oc -n kube-system get secret aws-creds -o json | jq -r .'data["aws_secret_access_key"]' | base64 --decode)
EOF

else
  echo "Environment is not 'AWS' and/or cluster domain is not 'devshift.org'.  Credentials not extracted."
fi

export OIDC_BUCKET_NAME=$CLUSTER_NAME_HSHIFT-$CLUSTER_ID_HSHIFT
export AWS_PROFILE=$INFRA_NAME
echo -e "\nCreating OIDC bucket with name '$OIDC_BUCKET_NAME' and AWs profile '$AWS_PROFILE'."

CMD_AWS_CREATE_BUCKET="aws s3api create-bucket --acl public-read --bucket $OIDC_BUCKET_NAME --region $REGION"
# https://docs.aws.amazon.com/cli/latest/reference/s3api/create-bucket.html#options



if [ "$REGION" != "us-east-1" ]; then
  CMD_AWS_CREATE_BUCKET="$CMD_AWS_CREATE_BUCKET --create-bucket-configuration LocationConstraint=$REGION"
fi
eval "$CMD_AWS_CREATE_BUCKET"

# Login to cluster.
echo -e "\nLogging in to cluster ' $CLUSTER_ID_HSHIFT'."
 

 

echo -e "\nCalling commands inside cluster ' $CLUSTER_ID_HSHIFT'."

# Grant yourself cluster-admin permissions so you can use the hypershift cli.
oc adm policy add-cluster-role-to-user cluster-admin $(oc whoami) --as backplane-cluster-admin

echo -e "\nRunning /usr/local/bin/hypershift install."
export AWS_PROFILE=default
/usr/local/bin/hypershift install \
  --oidc-storage-provider-s3-bucket-name "$OIDC_BUCKET_NAME" \
  --oidc-storage-provider-s3-credentials "$CLUSTER_AWS_CREDS_FILE" \
  --oidc-storage-provider-s3-region "$REGION"
  
  echo "\nCreating Hosted control plane."

  
  # Pick a name for the Hosted Control Plane (aka. child hypershift cluster..)
  export HCP_NAME=$CLUSTER_NAME_HSHIFT-$RANDOM
  echo "\nHCP Name: '$HCP_NAME'"
  
  # Create a Hosted Control Plane with 2 workers using the base domain from  $CLUSTER_ID_HSHIFT
  export BASE_DOMAIN=$(oc get infrastructure cluster -o jsonpath='{.status.apiServerInternalURI}' | cut -d\. -f3- | cut -d: -f1)
  FILENAME_LOG_CREATE=create-cluster-$HCP_NAME-$(date +%s).log
  echo "\FILENAME_LOG_CREATE Name: '$FILENAME_LOG_CREATE'"

  export AWS_PROFILE="default" # switch back
  echo "\nRunning /usr/local/bin/hypershift create cluster for $HCP_NAME" 
  /usr/local/bin/hypershift create cluster aws \
    --name "$HCP_NAME" \
    --node-pool-replicas=2 \
    --base-domain "$BASE_DOMAIN" \
    --pull-secret "$PULL_SECRET" \
    --aws-creds "$CLUSTER_AWS_CREDS_FILE" \
    --region $REGION 2>&1 | \
    tee "$FILENAME_LOG_CREATE"
  
  # Get the infrastructure ID for the HCP.
  # Important if you need to delete infra but the cluster didn't get created.
  # See cli output, probably first line.  Look for "Creating infrastructure".
  export HCP_INFRA_ID=$(grep "Creating infrastructure" "$FILENAME_LOG_CREATE" | sed 's/.*\({.*\)/\1/g' | jq -r .id)
  echo "\nHCP Infra ID: '$HCP_INFRA_ID'"

  # Remove quotas.  Might need to do this again when hive puts them back!  
  # Common failure mode…
  oc delete clusterresourcequotas loadbalancer-quota  persistent-volume-quota
  echo "\nRemoving resource quotas for LB and PV."
  # Wait for HCP to provision.
  echo -n "Waiting for HCP to become Available."; \
  HCP_AVAILABLE=$(oc -n clusters get hostedcluster $HCP_NAME -o json | jq -r '.status.conditions[] | select(.type == "Available") | .status'); \
  while [ "$HCP_AVAILABLE" == "False" ];
  do
      echo -n "."
      sleep 15
      HCP_AVAILABLE=$(oc -n clusters get hostedcluster $HCP_NAME -o json | jq -r '.status.conditions[] | select(.type == "Available") | .status')
  done; \
  echo -n -e "\nWaiting for HCP to be Completed."; \
  HCP_STATE=$(oc -n clusters get hostedcluster $HCP_NAME -o json | jq -r '.status.version.history[0].state'); \
  while [ "$HCP_STATE" != "Completed" ];
  do
      echo -n "."
      sleep 15
      HCP_STATE=$(oc -n clusters get hostedcluster $HCP_NAME -o json | jq -r '.status.version.history[0].state')
  done; \
  echo -e "\nHCP is ready!"


