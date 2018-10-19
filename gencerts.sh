#!/bin/bash -e
#
function usage() {
    >&2 cat << EOF
Usage: ./gencerts.sh etcd|k8s
EOF
exit 1
}

if [ -z "$1" ]; then 
    usage
fi

if [[ "$1" != "etcd" && "$1" != "k8s" ]]; then
    usage
fi

read -p "Enter Domain Name [ilinux.io]: " BASE_DOMAIN
BASE_DOMAIN=${BASE_DOMAIN:-ilinux.io}
export BASE_DOMAIN

if [ "$1" == 'k8s' ]; then
    read -p "Enter Kubernetes Cluster Name [kubernetes]: " CLUSTER_NAME
    echo -n -e "Enter the IP Address in default namespace \n  of the Kubernetes API Server[10.96.0.1]: "
    read  APISERVER_CLUSTER_IP

    CLUSTER_NAME=${CLUSTER_NAME:-kubernetes}
    APISERVER_CLUSTER_IP=${APISERVER_CLUSTER_IP:-10.96.0.1}

    export CLUSTER_NAME APISERVER_CLUSTER_IP

    bash ./k8s-certs-gen.sh kubernetes
fi


if [ "$1" == 'etcd' ]; then
    bash ./etcd-certs-gen.sh etcd
fi
