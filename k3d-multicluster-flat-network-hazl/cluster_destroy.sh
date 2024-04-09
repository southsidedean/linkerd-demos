#!/bin/bash
# cluster_destroy.sh
# Demo script for the k3d-multicluster-flat-network-hazl GitHub repository
# https://github.com/southsidedean/linkerd-demos/tree/main/k3d-multicluster-flat-network-hazl
# Automates cluster deletion and cleans up the kubectl contexts
# Tom Dean | Buoyant
# Last edit: 4/9/2024

# Remove the k3d clusters

k3d cluster delete source target
k3d cluster list

# Remove the kubectl contexts: hazl

kubectx -d source
kubectx -d target
kubectx

exit 0
