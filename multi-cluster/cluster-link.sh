#!/bin/env bash
set -e

if [ -z "${1}" ]
then
  clusters=(east west)
else
  clusters=("${@:1}")
fi


for c in "${clusters[@]}"
{
  # Load config
  civo k8s config "${c}" > ~/.kube/configs/"${c}"
  chmod 600 ~/.kube/configs/"${c}"
  
  # Allow BCloud
  kubectl apply -f manifests/finalizers/allow-bcloud.yaml
  linkerd check
  
}
linkerd multicluster link  --kubeconfig ~/.kube/configs/"${clusters[0]}" --cluster-name "${clusters[0]}" | kubectl apply --kubeconfig ~/.kube/configs/"${clusters[1]}" -f -
linkerd multicluster link  --kubeconfig ~/.kube/configs/"${clusters[1]}" --cluster-name "${clusters[1]}" | kubectl apply --kubeconfig ~/.kube/configs/"${clusters[0]}" -f -
