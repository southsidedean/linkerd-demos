#!/bin/bash
# deploy-httproute-clusters.sh
# Cluster deployment script for the k3d-multicluster-playground GitHub repository
# https://github.com/southsidedean/linkerd-demos/tree/main/k3d-multicluster-playground
# Automates cluster creation, Linkerd installation and installs the k3d-$CLUSTER_B_NAME application
# Tom Dean | Buoyant
# Last edit: 10/7/2024

# Let's set some variables!

# BEL: Stable
#BEL_VERSION=enterprise-2.16.0
#CLI_VERSION=install

# BEL: Preview
BEL_VERSION=preview-24.10.4
CLI_VERSION=install-preview

# Cluster Naming Variables
CLUSTER_A_PREFIX=cluster-a
CLUSTER_B_NAME=cluster-b

# Cluster A Count
CLUSTER_A_COUNT=3

# Viz Version
VIZ_VERSION=edge-24.10.1

# Let's go!

set -xeuo pipefail

# Create the k3d cluster

for i in `count 1 $CLUSTER_A_COUNT`
do
k3d cluster delete $CLUSTER_A_PREFIX$i
done

k3d cluster delete $CLUSTER_B_NAME

# This section creates the k3d clusters
# From https://gist.github.com/olix0r/2f2db5bb60731b5b3fd584523f53a60c
# olix0r/flat-network.sh
# which is forked from alpeb/flat-network.sh
# Minor tweaks to fit this application

k3d_api_ready() {
    name=$1
    for i in {1..6} ; do
        if kubectl --context=k3d-$name cluster-info >/dev/null ; then return ; fi
        sleep 10
    done
    exit 1
}

k3d_dns_ready() {
    name=$1
    while [ $(kubectl --context=k3d-$name get po -n kube-system -l k8s-app=kube-dns -o json |jq '.items | length') = "0" ]; do sleep 1 ; done
    kubectl --context=k3d-$name wait pod --for=condition=ready \
        --namespace=kube-system --selector=k8s-app=kube-dns \
        --timeout=1m
}

create_cluster() {
    name=$1
    k3d cluster create $name -c cluster/cluster.yaml --kubeconfig-update-default
    k3d_api_ready "$name"
    k3d_dns_ready "$name"
}

for i in `seq 1 $CLUSTER_A_COUNT`
do
create_cluster $CLUSTER_A_PREFIX$i
done

create_cluster $CLUSTER_B_NAME

# add routes for each node in cluster-b to all cluster-a nodes
for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl --context=k3d-$CLUSTER_B_NAME get node -o json | \
jq -r '.items[] | .metadata.name + "\t" + .spec.podCIDR + "\t" + (.status.addresses[] | select(.type == "InternalIP") | .address)' | \
  while IFS=$'\t' read -r sname scidr sip; do
    kubectl --context=$CLUSTER_A_PREFIX$i get node -o json | \
    jq -r '.items[] | .metadata.name + "\t" + .spec.podCIDR + "\t" + (.status.addresses[] | select(.type == "InternalIP") | .address)' | \
      while IFS=$'\t' read -r tname tcidr tip; do
        docker exec "${sname}" ip route add "${tcidr}" via "${tip}"
        docker exec "${tname}" ip route add "${scidr}" via "${sip}"
    done
  done
done

k3d cluster list

# Configure the kubectl context

#kubectx -d k3d-$CLUSTER_B_NAME
#kubectx -d $CLUSTER_A_PREFIX$i
#kubectx k3d-$CLUSTER_B_NAME=k3d-k3d-$CLUSTER_B_NAME
#kubectx $CLUSTER_A_PREFIX$i=k3d-$CLUSTER_A_PREFIX$i
#kubectx k3d-$CLUSTER_B_NAME
kubectx

# Create fresh root certificates for mTLS

cd certs
rm -f *.{crt,key}
step certificate create root.linkerd.cluster.local ca.crt ca.key \
--profile root-ca --no-password --insecure
step certificate create identity.linkerd.cluster.local issuer.crt issuer.key \
--profile intermediate-ca --not-after 8760h --no-password --insecure \
--ca ca.crt --ca-key ca.key
ls -la
cd ..

# Read in license, Buoyant Cloud and cluster name information from the settings.sh file

source settings.sh

# Install the CLI

curl https://enterprise.buoyant.io/$CLI_VERSION | sh
export PATH=~/.linkerd2/bin:$PATH
linkerd version

# Perform pre-installation checks

linkerd check --pre --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
linkerd check --pre --context k3d-$CLUSTER_A_PREFIX$i
done

# Install Buoyant Enterprise Linkerd Operator and Buoyant Cloud Agents using Helm
# Debug metrics are enabled to use the Buoyant Cloud Grafana instance

helm repo add linkerd-buoyant https://helm.buoyant.cloud
helm repo update

helm install linkerd-buoyant \
  --create-namespace \
  --namespace linkerd-buoyant \
  --kube-context k3d-$CLUSTER_B_NAME \
  --set metadata.agentName=$CLUSTER_B_NAME \
  --set api.clientID=$API_CLIENT_ID \
  --set api.clientSecret=$API_CLIENT_SECRET \
linkerd-buoyant/linkerd-buoyant

for i in `seq 1 $CLUSTER_A_COUNT`
do
helm install linkerd-buoyant \
  --create-namespace \
  --namespace linkerd-buoyant \
  --kube-context k3d-$CLUSTER_A_PREFIX$i \
  --set metadata.agentName=$CLUSTER_A_PREFIX$i \
  --set api.clientID=$API_CLIENT_ID \
  --set api.clientSecret=$API_CLIENT_SECRET \
linkerd-buoyant/linkerd-buoyant
done

kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant --context k3d-$CLUSTER_A_PREFIX$i
done

linkerd buoyant check --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
linkerd buoyant check --context k3d-$CLUSTER_A_PREFIX$i
done

# Create linkerd-identity-issuer secret using root certificates

cat <<EOF > linkerd-identity-secret.yaml
apiVersion: v1
data:
  ca.crt: $(base64 < certs/ca.crt | tr -d '\n')
  tls.crt: $(base64 < certs/issuer.crt| tr -d '\n')
  tls.key: $(base64 < certs/issuer.key | tr -d '\n')
kind: Secret
metadata:
  name: linkerd-identity-issuer
  namespace: linkerd
type: kubernetes.io/tls
EOF

kubectl apply -f linkerd-identity-secret.yaml --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl apply -f linkerd-identity-secret.yaml --context k3d-$CLUSTER_A_PREFIX$i
done

kubectl get secrets  -n linkerd --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl get secrets  -n linkerd --context k3d-$CLUSTER_A_PREFIX$i
done

# Create and apply Control Plane CRDs to trigger BEL Operator
# This will create the Control Plane on the cluster
# Press CTRL-C to exit each watch command

cat <<EOF > linkerd-control-plane-config.yaml
apiVersion: linkerd.buoyant.io/v1alpha1
kind: ControlPlane
metadata:
  name: linkerd-control-plane
spec:
  components:
    linkerd:
      version: $BEL_VERSION
      license: $BUOYANT_LICENSE
      controlPlaneConfig:
        proxy:
          image:
            version: $BEL_VERSION
        identityTrustAnchorsPEM: |
$(sed 's/^/          /' < certs/ca.crt )
        identity:
          issuer:
            scheme: kubernetes.io/tls
        destinationController:
          additionalArgs:
           # - -ext-endpoint-zone-weights
EOF

kubectl apply -f linkerd-control-plane-config.yaml --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl apply -f linkerd-control-plane-config.yaml --context k3d-$CLUSTER_A_PREFIX$i
done

watch -n 1 kubectl get pods -A -o wide --sort-by .metadata.namespace --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
watch -n 1 kubectl get pods -A -o wide --sort-by .metadata.namespace --context k3d-$CLUSTER_A_PREFIX$i
done

# Run a Linkerd check after creating Control Planes

linkerd check --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
linkerd check --context k3d-$CLUSTER_A_PREFIX$i
done

# Create the Data Plane for the linkerd-buoyant namespace

cat <<EOF > linkerd-data-plane-config.yaml
---
apiVersion: linkerd.buoyant.io/v1alpha1
kind: DataPlane
metadata:
  name: dataplane-linkerd-buoyant
  namespace: linkerd-buoyant
spec:
  workloadSelector:
    matchLabels: {}
EOF

kubectl apply -f linkerd-data-plane-config.yaml --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl apply -f linkerd-data-plane-config.yaml --context k3d-$CLUSTER_A_PREFIX$i
done

# Monitor the status of the rollout of the Buoyant Cloud Metrics Daemonset

kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant --context k3d-$CLUSTER_A_PREFIX$i
done

# Run a proxy check

sleep 75
linkerd check --proxy -n linkerd-buoyant --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
linkerd check --proxy -n linkerd-buoyant --context k3d-$CLUSTER_A_PREFIX$i
done

# Install Linkerd Viz to Enable Success Rate Metrics

linkerd viz install --set linkerdVersion=$VIZ_VERSION --context k3d-$CLUSTER_B_NAME | kubectl apply -f - --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
linkerd viz install --set linkerdVersion=$VIZ_VERSION --context k3d-$CLUSTER_A_PREFIX$i | kubectl apply -f - --context $CLUSTER_A_PREFIX$i
done

# Enable Inbound Latency Metrics
# These are disabled by default in the Buoyant Cloud Agent
# Patch with the buoyant-cloud-metrics.yaml manifest
# Restart the buoyant-cloud-metrics daemonset

kubectl apply -f buoyant-cloud-metrics.yaml --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl apply -f buoyant-cloud-metrics.yaml --context k3d-$CLUSTER_A_PREFIX$i
done

kubectl -n linkerd-buoyant rollout restart ds buoyant-cloud-metrics --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl -n linkerd-buoyant rollout restart ds buoyant-cloud-metrics --context k3d-$CLUSTER_A_PREFIX$i
done

# Deploy the orders application to cluster-b
# Deploy the warehouse application to all the cluster-a clusters
# Press CTRL-C to exit each watch commands

kubectl apply -k orders/orders --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl apply -k orders/warehouse --context k3d-$CLUSTER_A_PREFIX$i
done

watch -n 1 kubectl get pods -n orders -o wide --sort-by .spec.nodeName --context k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
watch -n 1 kubectl get pods -n warehouse -o wide --sort-by .spec.nodeName --context k3d-$CLUSTER_A_PREFIX$i
done

# Deploy the Data Plane for the orders namespace to cluster-b

cat <<EOF > linkerd-data-plane-orders-config.yaml
---
apiVersion: linkerd.buoyant.io/v1alpha1
kind: DataPlane
metadata:
  name: dataplane-orders
  namespace: orders
spec:
  workloadSelector:
    matchLabels: {}
EOF

kubectl apply -f linkerd-data-plane-orders-config.yaml --context k3d-$CLUSTER_B_NAME

# Deploy the Data Planes for the warehouse namespace on all cluster-a clusters

cat <<EOF > linkerd-data-plane-warehouse-config.yaml
---
apiVersion: linkerd.buoyant.io/v1alpha1
kind: DataPlane
metadata:
  name: dataplane-warehouse
  namespace: warehouse
spec:
  workloadSelector:
    matchLabels: {}
EOF

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl apply -f linkerd-data-plane-warehouse-config.yaml --context k3d-$CLUSTER_A_PREFIX$i
done

exit 0
