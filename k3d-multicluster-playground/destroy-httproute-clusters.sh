#!/bin/bash
# destroy-httproute-clusters.sh
# Demo script for the k3d-multicluster-flat-network-hazl GitHub repository
# https://github.com/southsidedean/linkerd-demos/tree/main/k3d-multicluster-flat-network-hazl
# Automates cluster deletion and cleans up the kubectl contexts
# Tom Dean | Buoyant
# Last edit: 10/7/2024

# Cluster Naming Variables
CLUSTER_A_PREFIX=cluster-a
CLUSTER_B_NAME=cluster-b

# Cluster A Count
CLUSTER_A_COUNT=3

# Remove the k3d clusters

k3d cluster delete $CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
k3d cluster delete $CLUSTER_A_PREFIX$i
done

k3d cluster list

# Remove the kubectl contexts: hazl

kubectx -d k3d-$CLUSTER_B_NAME

for i in `seq 1 $CLUSTER_A_COUNT`
do
kubectx -d k3d-$CLUSTER_A_PREFIX$i
done

kubectx

exit 0
