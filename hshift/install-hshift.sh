 
# Extract AWS credentials to a file for use in hypershift CLI.
# Uses ~/.aws/ as the base director with the assumption that this is reasonably secure already.
export AWS_CREDS_FILE=~/.aws/credentials
export CLUSTER_AWS_CREDS_FILE=~/.aws/credentials.$CLUSTER_ID
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

export OIDC_BUCKET_NAME=$CLUSTER_NAME-$CLUSTER_ID
export AWS_PROFILE=$INFRA_NAME
echo -e "\nCreating OIDC bucket with name '$OIDC_BUCKET_NAME' and AWs profile '$AWS_PROFILE'."

CMD_AWS_CREATE_BUCKET="aws s3api create-bucket --acl public-read --bucket $OIDC_BUCKET_NAME --region $REGION"
# https://docs.aws.amazon.com/cli/latest/reference/s3api/create-bucket.html#options



if [ "$REGION" != "us-east-1" ]; then
  CMD_AWS_CREATE_BUCKET="$CMD_AWS_CREATE_BUCKET --create-bucket-configuration LocationConstraint=$REGION"
fi
eval "$CMD_AWS_CREATE_BUCKET"

# Login to cluster.
echo -e "\nLogging in to cluster '$CLUSTER_ID'."
 

 

echo -e "\nCalling commands inside cluster '$CLUSTER_ID'."

# Grant yourself cluster-admin permissions so you can use the hypershift cli.
oc adm policy add-cluster-role-to-user cluster-admin $(oc whoami) --as backplane-cluster-admin

echo -e "\nRunning /usr/local/bin/hypershift install."
export AWS_PROFILE=default
/usr/local/bin/hypershift install \
  --oidc-storage-provider-s3-bucket-name "$OIDC_BUCKET_NAME" \
  --oidc-storage-provider-s3-credentials "$CLUSTER_AWS_CREDS_FILE" \
  --oidc-storage-provider-s3-region "$REGION"

