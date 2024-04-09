#!/usr/bin/env bash

set -xeuo pipefail

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
