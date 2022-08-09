# Setup env var for pull secret
export PULL_SECRET=~/Downloads/pull-secret.json

# Pick a region.
export REGION=us-east-1

ocm create cluster $CLUSTER_NAME --region $REGION
export CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="managed='true' AND name='$CLUSTER_NAME'" | jq -r '.items[0].id')

# Wait for cluster to finish installing.
CLUSTER_STATE=$(ocm get /api/clusters_mgmt/v1/clusters/$CLUSTER_ID | jq -r '.status.state')
echo "Cluster state is '$CLUSTER_STATE'.  Waiting until it changes to installed. This may take up to 40 minutes. Checks every 10 seconds."
 
while  [ "$CLUSTER_STATE" = "installing" ]||[ "$CLUSTER_STATE" = "inpendingstalling" ]; do
  sleep 10
  CLUSTER_STATE=$(ocm get /api/clusters_mgmt/v1/clusters/$CLUSTER_ID | jq -r '.status.state')
  printf "Cluster is in state %s." "$CLUSTER_STATE"
done
printf "Cluster is now in state %s." "$CLUSTER_STATE"
printf  "\nProceed with the following to finish hypershift install.\n
1.Log in to cluster %s:\nocm backplane tunnel %s\nocm backplane login %s\n 
2.Run hshift install:\nCLUSTER_ID=%s  ./install-hshift.sh" "$CLUSTER_ID" "$CLUSTER_ID" "$CLUSTER_ID" "$CLUSTER_ID"
