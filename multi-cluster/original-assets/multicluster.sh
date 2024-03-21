#!/bin/bash

cycle_cluster () {
    port_args=

    case "$1" in
        --map-ports)
            port_args='-p 80:80@loadbalancer -p 443:443@loadbalancer'
            shift
            ;;
        --*)
            echo "Unknown option $1" >&2
            exit 1
            ;;
    esac

    ctx="$1"
    cidr="$2"

    k3d cluster delete $ctx >/dev/null 2>&1

    k3d cluster create $ctx \
        $port_args \
        --agents=0 \
        --servers=1 \
        --network=face-network \
        --k3s-arg '--disable=local-storage,traefik,metrics-server@server:*;agents:*' \
        --k3s-arg "--cluster-cidr=${cidr}@server:*"
        # --k3s-arg "--cluster-domain=${ctx}@server:*"

    kubectl config delete-context $ctx >/dev/null 2>&1
    kubectl config rename-context k3d-$ctx $ctx
}

get_network_info () {
    ctx="$1"
    REMAINING=60
    echo "Getting $ctx cluster network info..." >&2

    while true; do
        cidr=$(kubectl --context $ctx get node k3d-$ctx-server-0 -o jsonpath='{.spec.podCIDR}')
        router=$(kubectl --context $ctx get node k3d-$ctx-server-0 -o jsonpath='{.status.addresses[?(.type=="InternalIP")].address}')

        echo "$ctx: cidr=$cidr router=$router" >&2

        if [ -n "$cidr" -a -n "$router" ]; then break; fi
        REMAINING=$(( $REMAINING - 1 ))
        printf "." >&2
        sleep 1
    done

    if [ $REMAINING -eq 0 ]; then
        echo "Timed out waiting for $ctx network info" >&2
        exit 1
    else
        printf "\n" >&2
        echo "$cidr $router"
    fi
}

cycle_cluster --map-ports east  "10.23.1.0/24"
cycle_cluster             west  "10.23.2.0/24"

#@SHOW

# Grab network info for each cluster...

east_net=$(get_network_info east)
west_net=$(get_network_info west)


east_cidr=$(echo $east_net | cut -d' ' -f1)
east_router=$(echo $east_net | cut -d' ' -f2)
west_cidr=$(echo $west_net | cut -d' ' -f1)
west_router=$(echo $west_net | cut -d' ' -f2)


docker exec -it k3d-east-server-0 ip route add ${west_cidr} via ${west_router}

docker exec -it k3d-west-server-0 ip route add ${east_cidr} via ${east_router}
