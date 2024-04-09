#!/usr/bin/env bash

k3simage='rancher/k3s:v1.28.7-k3s1'

zones=(east central west)

cluster_cidr() {
    echo "apiVersion: networking.k8s.io/v1alpha1
kind: ClusterCIDR
metadata:
  name: new-cidr
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
        - key: topology.kubernetes.io/zone
          operator: Exists
  perNodeHostBits: 8
  ipv4: $1"
}

k3d_api_ready() {
    for i in {1..6} ; do
        if kubectl cluster-info >/dev/null ; then return ; fi
        sleep 10
    done
    exit 1
}

k3d_dns_ready() {
    while [ $(kubectl get po -n kube-system -l k8s-app=kube-dns -o json |jq '.items | length') = "0" ]; do sleep 1 ; done
    kubectl wait pod --for=condition=ready \
        --namespace=kube-system --selector=k8s-app=kube-dns \
        --timeout=1m
}

create_cluster() {
    name=$1
    cluster_cidr=$2
    multicluster_cidr=$3
    k3d cluster create $name --image=$k3simage --agents='0' --servers='1' --network='mcnet' \
        --k3s-arg --disable=local-storage,metrics-server,servicelb,traefik@server:* \
        --k3s-arg --cluster-cidr=$cluster_cidr@server:* \
        --k3s-arg --cluster-domain=$name@server:*\
        --k3s-arg '--debug@server:*' \
        --k3s-arg --multi-cluster-cidr@server:* \
        --k3s-arg '--runtime-config=networking.k8s.io/v1alpha1=true@server:*' \
        --kubeconfig-update-default \
        --verbose
    k3d_api_ready
    k3d_dns_ready
    cluster_cidr $multicluster_cidr | kubectl apply -f -
    for zone in "${zones[@]}"; do
        k3d node create $name-$zone -c $name --k3s-node-label topology.kubernetes.io/zone=zone-$zone
    done
    kubectl taint nodes k3d-$name-server-0 node-role.kubernetes.io/master=:NoSchedule
}

create_cluster "source" "10.23.0.0/24" "10.247.0.0/16"
create_cluster "target" "10.24.0.0/24" "10.248.0.0/16"

# add routes for each node in source to each node in target
for zone_source in "${zones[@]}"; do
    for zone_target in "${zones[@]}"; do
        ip_route_add=$(kubectl --context k3d-target get node k3d-target-$zone_target-0 -o jsonpath='ip route add {.spec.podCIDR} via {.status.addresses[?(.type=="InternalIP")].address}')
        docker exec -it k3d-source-$zone_source-0 $ip_route_add
    done
done

# create a server on each zone in the target cluster
helm repo add podinfo https://stefanprodan.github.io/podinfo
kubectl create ns test
for zone in "${zones[@]}"; do
    helm install backend-$zone -n test --set "nodeSelector.topology\.kubernetes\.io/zone=zone-$zone" --wait podinfo/podinfo
done

# try to connect from each zone in source to each zone in target
kubectl config use-context k3d-source
for zone_source in "${zones[@]}"; do
    for zone_target in "${zones[@]}"; do
        target_ip=$(kubectl --context k3d-target -n test get po -l app.kubernetes.io/name=backend-$zone_target-podinfo -o jsonpath="{.items[*].status.podIP}")
        printf 'Connecting from source-%s to target-%s:\n' "$zone_source" "$zone_target"
        kubectl run -it --rm --restart Never curl --image curlimages/curl \
            --overrides="{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"zone-$zone_source\"}}}" -- \
            curl --connect-timeout 5 http://$target_ip:9898
    done
done
