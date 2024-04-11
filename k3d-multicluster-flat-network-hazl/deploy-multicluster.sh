#!/bin/bash
# deploy-multicluster.sh
# Demo script for the k3d-multicluster-flat-network-hazl GitHub repository
# https://github.com/southsidedean/linkerd-demos/tree/main/k3d-multicluster-flat-network-hazl
# Automates multi-cluster deployment
# Tom Dean | Buoyant
# Last edit: 4/10/2024

# Step 1: Add a Hosts Entry to CoreDNS

kubectl get cm coredns -n kube-system -o yaml --context orders -o yaml | grep -Ev "creationTimestamp|resourceVersion|uid" > coredns.yaml
sed -i .orig 's/host.k3d.internal/host.k3d.internal\ kubernetes/g' coredns.yaml
cat coredns.yaml
kubectl apply -f coredns.yaml -n kube-system --context orders
kubectl rollout restart deploy coredns -n kube-system --context orders
kubectl get cm coredns -n kube-system -o yaml --context orders -o yaml

# Step 2: Install the Multi-Cluster Extension

source settings.sh
helm repo add linkerd-buoyant https://helm.buoyant.cloud
helm repo update
helm install linkerd-multicluster \
  --create-namespace \
  --namespace linkerd-multicluster \
  --kube-context orders \
  --set linkerd-multicluster.gateway.enabled=false \
  --set license=$BUOYANT_LICENSE \
  linkerd-buoyant/linkerd-enterprise-multicluster
helm install linkerd-multicluster \
  --create-namespace \
  --namespace linkerd-multicluster \
  --kube-context warehouse \
  --set linkerd-multicluster.gateway.enabled=false \
  --set license=$BUOYANT_LICENSE \
  linkerd-buoyant/linkerd-enterprise-multicluster
linkerd --context=orders multicluster check
linkerd --context=warehouse multicluster check
kubectl apply -f policy.yaml --context orders

# Step 3: Link the Clusters

linkerd --context=warehouse multicluster link --cluster-name warehouse --gateway=false > multicluster-link-orig.yaml
KC1=`linkerd --context=warehouse multicluster link --cluster-name warehouse --gateway=false | grep kubeconfig: | uniq | awk {'print $2'}` ; KC2=`echo $KC1 | base64 -d | sed 's/0\.0\.0\.0/kubernetes/g' | base64` ; awk -f mc.awk "$KC1" "$KC2" multicluster-link-orig.yaml > multicluster-link.yaml
kubectl apply -f multicluster-link.yaml --context orders
kubectl get links -A --context=orders

# Step 4: Export the 'fulfillment' Service to the 'orders' Cluster

kubectl get svc -A --context=orders
kubectl get svc -A --context=warehouse
kubectl --context=warehouse label svc -n orders fulfillment mirror.linkerd.io/exported=remote-discovery

exit 0
