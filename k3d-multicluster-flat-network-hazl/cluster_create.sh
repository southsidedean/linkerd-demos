#!/bin/bash
# cluster_create.sh
# Demo script for the k3d-multicluster-flat-network-hazl GitHub repository
# https://github.com/southsidedean/linkerd-demos/tree/main/k3d-multicluster-flat-network-hazl
# Automates cluster creation, Linkerd installation and installs the Orders application
# Tom Dean | Buoyant
# Last edit: 4/9/2024
#set -xeuo pipefail

# Create the k3d cluster

k3d cluster delete source target

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
    k3d cluster create -c cluster/"$name".yaml --kubeconfig-update-default
    k3d_api_ready "$name"
    k3d_dns_ready "$name"
}

create_cluster source
create_cluster target

# add routes for each node in source to each node in target
kubectl --context=k3d-source get node -o json | \
jq -r '.items[] | .metadata.name + "\t" + .spec.podCIDR + "\t" + (.status.addresses[] | select(.type == "InternalIP") | .address)' | \
while IFS=$'\t' read -r sname scidr sip; do
    kubectl --context=k3d-target get node -o json | \
    jq -r '.items[] | .metadata.name + "\t" + .spec.podCIDR + "\t" + (.status.addresses[] | select(.type == "InternalIP") | .address)' | \
    while IFS=$'\t' read -r tname tcidr tip; do
        docker exec "${sname}" ip route add "${tcidr}" via "${tip}"
        docker exec "${tname}" ip route add "${scidr}" via "${sip}"
    done
done

k3d cluster list

# Configure the kubectl context

kubectx -d source
kubectx -d target
kubectx source=k3d-source
kubectx target=k3d-target
kubectx source
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

curl https://enterprise.buoyant.io/install | sh
export PATH=~/.linkerd2/bin:$PATH
linkerd version

# Perform pre-installation checks

linkerd check --pre --context=source
linkerd check --pre --context=target

# Install Buoyant Enterprise Linkerd Operator and Buoyant Cloud Agents using Helm
# Debug metrics are enabled to use the Buoyant Cloud Grafana instance

helm repo add linkerd-buoyant https://helm.buoyant.cloud
helm repo update

helm install linkerd-buoyant \
  --create-namespace \
  --namespace linkerd-buoyant \
  --kube-context source \
  --set metadata.agentName=$CLUSTER1_NAME \
  --set api.clientID=$API_CLIENT_ID \
  --set api.clientSecret=$API_CLIENT_SECRET \
  --set metrics.debugMetrics=true \
  --set agent.logLevel=debug \
  --set metrics.logLevel=debug \
linkerd-buoyant/linkerd-buoyant

helm install linkerd-buoyant \
  --create-namespace \
  --namespace linkerd-buoyant \
  --kube-context target \
  --set metadata.agentName=$CLUSTER2_NAME \
  --set api.clientID=$API_CLIENT_ID \
  --set api.clientSecret=$API_CLIENT_SECRET \
  --set metrics.debugMetrics=true \
  --set agent.logLevel=debug \
  --set metrics.logLevel=debug \
linkerd-buoyant/linkerd-buoyant

kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant --context=source
kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant --context=target
linkerd buoyant check --context source
linkerd buoyant check --context target

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

kubectl apply -f linkerd-identity-secret.yaml --context=source
kubectl apply -f linkerd-identity-secret.yaml --context=target

kubectl get secrets  -n linkerd --context=source
kubectl get secrets  -n linkerd --context=target

# Create and apply Control Plane CRDs to trigger BEL Operator
# This will create the Control Plane on the cluster
# Press CTRL-C to exit each watch command

cat <<EOF > linkerd-control-plane-config-hazl.yaml
apiVersion: linkerd.buoyant.io/v1alpha1
kind: ControlPlane
metadata:
  name: linkerd-control-plane
spec:
  components:
    linkerd:
      version: enterprise-2.15.2
      license: $BUOYANT_LICENSE
      controlPlaneConfig:
        proxy:
          image:
            version: enterprise-2.15.2
        identityTrustAnchorsPEM: |
$(sed 's/^/          /' < certs/ca.crt )
        identity:
          issuer:
            scheme: kubernetes.io/tls
        destinationController:
          additionalArgs:
           # - -ext-endpoint-zone-weights
EOF

kubectl apply -f linkerd-control-plane-config-hazl.yaml --context=source
kubectl apply -f linkerd-control-plane-config-hazl.yaml --context=target

watch -n 1 kubectl get pods -A -o wide --sort-by .metadata.namespace --context=source
watch -n 1 kubectl get pods -A -o wide --sort-by .metadata.namespace --context=target

# Run a Linkerd check after creating Control Planes

linkerd check --context source
linkerd check --context target

# Create the Data Plane for the linkerd-buoyant namespace

cat <<EOF > linkerd-data-plane-config.yaml
---
apiVersion: linkerd.buoyant.io/v1alpha1
kind: DataPlane
metadata:
  name: linkerd-buoyant
  namespace: linkerd-buoyant
spec:
  workloadSelector:
    matchLabels: {}
EOF

kubectl apply -f linkerd-data-plane-config.yaml --context=source
kubectl apply -f linkerd-data-plane-config.yaml --context=target

# Monitor the status of the rollout of the Buoyant Cloud Metrics Daemonset

kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant --context=source
kubectl rollout status daemonset/buoyant-cloud-metrics -n linkerd-buoyant --context=target

# Run a proxy check

sleep 30
linkerd check --proxy -n linkerd-buoyant --context source
linkerd check --proxy -n linkerd-buoyant --context target

# Deploy the Orders application to both clusters
# Press CTRL-C to exit each watch command

kubectl apply -k orders/source --context=source
kubectl apply -k orders/target --context=target

#watch -n 1 kubectl get pods -n orders -o wide --sort-by .spec.nodeName --context=source
#watch -n 1 kubectl get pods -n orders -o wide --sort-by .spec.nodeName --context=target
watch -n 1 kubectl get pods -n orders -o wide --context=source
watch -n 1 kubectl get pods -n orders -o wide --context=target

# Deploy the Data Plane for the orders namespace

cat <<EOF > linkerd-data-plane-orders-config.yaml
---
apiVersion: linkerd.buoyant.io/v1alpha1
kind: DataPlane
metadata:
  name: linkerd-orders
  namespace: orders
spec:
  workloadSelector:
    matchLabels: {}
EOF

kubectl apply -f linkerd-data-plane-orders-config.yaml --context=source
kubectl apply -f linkerd-data-plane-orders-config.yaml --context=target

exit 0
