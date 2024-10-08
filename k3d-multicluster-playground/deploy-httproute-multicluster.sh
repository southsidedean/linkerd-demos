#!/bin/bash
# deploy-httproute-multicluster.sh
# Demo script for the k3d-multicluster-playground GitHub repository
# https://github.com/southsidedean/linkerd-demos/tree/main/k3d-multicluster-playground
# Automates multi-cluster deployment
# Tom Dean | Buoyant
# Last edit: 10/7/2024

# Let's set some variables!

# Cluster Naming Variables
CLUSTER_A_PREFIX=cluster-a
CLUSTER_B_NAME=cluster-b

# Cluster A Count
CLUSTER_A_COUNT=3

# Step 1: Add a Hosts Entry to CoreDNS

kubectl get cm coredns -n kube-system -o yaml --context k3d-$CLUSTER_B_NAME -o yaml | grep -Ev "creationTimestamp|resourceVersion|uid" > coredns.yaml
sed -i .orig 's/host.k3d.internal/host.k3d.internal\ kubernetes/g' coredns.yaml
cat coredns.yaml
kubectl apply -f coredns.yaml -n kube-system --context k3d-$CLUSTER_B_NAME
kubectl rollout restart deploy coredns -n kube-system --context k3d-$CLUSTER_B_NAME
kubectl get cm coredns -n kube-system -o yaml --context k3d-$CLUSTER_B_NAME -o yaml

# Step 2: Install the Multi-Cluster Extension

source settings.sh
helm repo add linkerd-buoyant https://helm.buoyant.cloud
helm repo update
helm install linkerd-multicluster \
  --create-namespace \
  --namespace linkerd-multicluster \
  --kube-context k3d-$CLUSTER_B_NAME \
  --set linkerd-multicluster.gateway.enabled=true \
  --set license=$BUOYANT_LICENSE \
  linkerd-buoyant/linkerd-enterprise-multicluster

for i in `seq 1 $CLUSTER_A_COUNT`
do
helm install linkerd-multicluster \
  --create-namespace \
  --namespace linkerd-multicluster \
  --kube-context k3d-$CLUSTER_A_PREFIX$i \
  --set linkerd-multicluster.gateway.enabled=true \
  --set license=$BUOYANT_LICENSE \
  linkerd-buoyant/linkerd-enterprise-multicluster
done

linkerd --context=k3d-$CLUSTER_B_NAME multicluster check

for i in `seq 1 $CLUSTER_A_COUNT`
do
linkerd --context=k3d-$CLUSTER_A_PREFIX$i multicluster check
done

kubectl apply -f policy.yaml --context k3d-$CLUSTER_B_NAME

# Step 3: Link the Clusters

for i in `seq 1 $CLUSTER_A_COUNT`
do
linkerd --context=k3d-$CLUSTER_A_PREFIX$i multicluster link --cluster-name $CLUSTER_A_PREFIX$i >> multicluster-link-orig-a$i.yaml
KC1=`linkerd --context=k3d-$CLUSTER_A_PREFIX$i multicluster link --cluster-name $CLUSTER_A_PREFIX$i | grep kubeconfig: | uniq | awk {'print $2'}` ; KC2=`echo $KC1 | base64 -d | sed 's/0\.0\.0\.0/kubernetes/g' | base64` ; awk -f mc.awk "$KC1" "$KC2" multicluster-link-orig-a$i.yaml >> multicluster-link.yaml
done

#linkerd --context=k3d-cluster-a1 multicluster link --cluster-name cluster-a1 >> multicluster-link-orig-a1.yaml
#KC1=`linkerd --context=k3d-cluster-a1 multicluster link --cluster-name cluster-a1 | grep kubeconfig: | uniq | awk {'print $2'}` ; KC2=`echo $KC1 | base64 -d | sed 's/0\.0\.0\.0/kubernetes/g' | base64` ; awk -f mc.awk "$KC1" "$KC2" multicluster-link-orig-a1.yaml >> multicluster-link.yaml
#linkerd --context=k3d-cluster-a2 multicluster link --cluster-name cluster-a2 >> multicluster-link-orig-a2.yaml
#KC1=`linkerd --context=k3d-cluster-a2 multicluster link --cluster-name cluster-a2 | grep kubeconfig: | uniq | awk {'print $2'}` ; KC2=`echo $KC1 | base64 -d | sed 's/0\.0\.0\.0/kubernetes/g' | base64` ; awk -f mc.awk "$KC1" "$KC2" multicluster-link-orig-a2.yaml >> multicluster-link.yaml
#linkerd --context=k3d-cluster-a3 multicluster link --cluster-name cluster-a3 >> multicluster-link-orig-a3.yaml
#KC1=`linkerd --context=k3d-cluster-a3 multicluster link --cluster-name cluster-a3 | grep kubeconfig: | uniq | awk {'print $2'}` ; KC2=`echo $KC1 | base64 -d | sed 's/0\.0\.0\.0/kubernetes/g' | base64` ; awk -f mc.awk "$KC1" "$KC2" multicluster-link-orig-a3.yaml >> multicluster-link.yaml

kubectl apply -f multicluster-link.yaml --context k3d-$CLUSTER_B_NAME
kubectl get links -A --context=k3d-$CLUSTER_B_NAME

# Step 4: Export the 'fulfillment' Service to the 'orders' Cluster

kubectl get svc -A --context=k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl get svc -A --context=k3d-$CLUSTER_A_PREFIX$i
done

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectl --context=k3d-$CLUSTER_A_PREFIX$i label svc -n orders fulfillment mirror.linkerd.io/exported=true
done

sleep 30
kubectl get svc -A --context=k3d-$CLUSTER_B_NAME

exit 0
