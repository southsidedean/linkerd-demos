#!/bin/bash
# cluster_destroy.sh
# Demo script for the k3d-multicluster-flat-network-hazl GitHub repository

# Automates cluster deletion and cleans up the kubectl contexts
# Tom Dean | Buoyant
# Last edit: 4/9/2024

# Remove the k3d clusters

k3d cluster delete source target
k3d cluster list

# Remove the kubectl contexts: hazl

kubectx -d k3d-source
kubectx -d k3d-target
kubectx

exit 0
