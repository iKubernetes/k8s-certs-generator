#!/bin/bash -e

function usage() {
    >&2 cat << EOF
Usage: ./k8s-certs-gen.sh

Set the following environment variables to run this script:

    BASE_DOMAIN     Base domain name of the cluster. For example if your API
                    server is running on "my-cluster-k8s.ilinux.io", the
                    base domain is "ilinux.io"

    CLUSTER_NAME    Name of the cluster. If your API server is running on the
                    domain "my-cluster-k8s.ilinux.io", the name of the cluster
                    is "my-cluster"

    APISERVER_CLUSTER_IP
                    Cluster IP address of the "kubernetes" service in the
                    "default" namespace.

    CA_CERT         Path to the pem encoded CA certificate of your cluster.
    CA_KEY          Path to the pem encoded CA key of your cluster.

    MASTERS      Name list. If all of your master's name is 
                    "master01.ilinux.io", "master02.ilinux.io" and "master03.ilinux.io",
		    the list value is "master01 master02 master03". 
EOF
    exit 1
}

if [ -z $BASE_DOMAIN ]; then
    usage
fi
if [ -z $CLUSTER_NAME ]; then
    usage
fi
if [ -z $APISERVER_CLUSTER_IP ]; then
    usage
fi
if [ -z "$MASTERS" ]; then
    usage
fi

export DIR="generated"
if [ $# -eq 1 ]; then
    DIR="$1"
fi

export CERT_DIR=$DIR/CA
mkdir -p $CERT_DIR

export CA_CERT="$CERT_DIR/ca.crt"
export CA_KEY="$CERT_DIR/ca.key"
if [ -f "$CA_CERT" -a -f "$CA_KEY" ]; then
    echo "Using the CA: $CA_CERT and $CA_KEY"
    read -p "pause" A
else
    echo "Generating CA key and self signed cert." 
    openssl genrsa -out $CERT_DIR/ca.key 4096
    openssl req -config openssl.conf \
        -new -x509 -days 3650 -sha256 \
        -key $CERT_DIR/ca.key -out $CERT_DIR/ca.crt \
	-subj "/CN=k8s-ca"
fi

# Configure expected OpenSSL CA configs.
touch $CERT_DIR/index
touch $CERT_DIR/index.txt
touch $CERT_DIR/index.txt.attr
echo 1000 > $CERT_DIR/serial
# Sign multiple certs for the same CN
echo "unique_subject = no" > $CERT_DIR/index.txt.attr

function openssl_req() {
    openssl genrsa -out ${1}/${2}.key 2048
    echo "Generating ${1}/${2}.csr"
    openssl req -config openssl.conf -new -sha256 \
        -key ${1}/${2}.key -out ${1}/${2}.csr -subj "$3"
}

function openssl_sign() {
    echo "Generating ${3}/${4}.crt"
    openssl ca -batch -config openssl.conf -extensions $5 -days 3650 -notext \
        -md sha256 -in ${3}/${4}.csr -out ${3}/${4}.crt \
        -cert ${1} -keyfile ${2}
}

# If supplied, generate a new etcd CA and associated certs.
if [ -n $FRONT_PROXY_CA_CERT ]; then
    front_proxy_dir=${DIR}/front-proxy
    if [ ! -d "$front_proxy_dir" ]; then
	mkdir $front_proxy_dir
    fi

    openssl genrsa -out ${front_proxy_dir}/front-proxy-ca.key 2048
    openssl req -config openssl.conf \
        -new -x509 -days 3650 -sha256 \
        -key ${front_proxy_dir}/front-proxy-ca.key \
        -out ${front_proxy_dir}/front-proxy-ca.crt -subj "/CN=front-proxy-ca"
    
    openssl_req ${front_proxy_dir} front-proxy-client "/CN=front-proxy-client"
    
    openssl_sign ${front_proxy_dir}/front-proxy-ca.crt ${front_proxy_dir}/front-proxy-ca.key ${front_proxy_dir} front-proxy-client client_cert
    rm -f ${front_proxy_dir}/*.csr
fi

# Generate and sihn CSRs for all components of masters
for master in $MASTERS; do
    master_dir="${DIR}/${master}"

    if [ ! -d "${master_dir}" ]; then
        mkdir -p ${master_dir}/{auth,pki}
    fi
    
    export MASTER_NAME=${master}

    openssl_req "${master_dir}/pki" apiserver "/CN=kube-apiserver"
    openssl_req "${master_dir}/pki" kube-controller-manager "/CN=system:kube-controller-manager"
    openssl_req "${master_dir}/pki" kube-scheduler "/CN=system:kube-scheduler"
    openssl_req "${master_dir}/pki" apiserver-kubelet-client "/CN=kube-apiserver-kubelet-client/O=system:masters"

    openssl_sign $CA_CERT $CA_KEY "${master_dir}/pki" apiserver apiserver_cert
    openssl_sign $CA_CERT $CA_KEY "${master_dir}/pki" kube-controller-manager master_component_client_cert
    openssl_sign $CA_CERT $CA_KEY "${master_dir}/pki" kube-scheduler master_component_client_cert
    openssl_sign $CA_CERT $CA_KEY "${master_dir}/pki" apiserver-kubelet-client client_cert
    rm -f ${master_dir}/pki/*.csr

    echo "Copy CA key and cert file to ${master_dir}"
    cp $CA_CERT $CA_KEY ${master_dir}/pki/

    echo "Copy front-proxy CA key and cert file to ${master_dir}"
    cp $front_proxy_dir/front-proxy* ${master_dir}/pki/

    echo "Generating the ServiceAccount key for apiserver"
    openssl ecparam -name secp521r1 -genkey -noout -out ${master_dir}/pki/sa.key
    openssl ec -in ${master_dir}/pki/sa.key -outform PEM -pubout -out ${master_dir}/pki/sa.pub

    echo "Generating kubeconfig for kube-controller-manager"
    cat > ${master_dir}/auth/controller-manager.conf << EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: https://${master}.${BASE_DOMAIN}:6443
    certificate-authority-data: $( openssl base64 -A -in $CA_CERT ) 
users:
- name: system:kube-controller-manager
  user:
    client-certificate-data: $( openssl base64 -A -in ${master_dir}/pki/kube-controller-manager.crt ) 
    client-key-data: $( openssl base64 -A -in ${master_dir}/pki/kube-controller-manager.key ) 
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: system:kube-controller-manager
  name: system:kube-controller-manager@${CLUSTER_NAME}
current-context: system:kube-controller-manager@${CLUSTER_NAME}
EOF

    echo "Generating kubeconfig for kube-scheduler"
    cat > ${master_dir}/auth/scheduler.conf << EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: https://${master}.${BASE_DOMAIN}:6443
    certificate-authority-data: $( openssl base64 -A -in $CA_CERT ) 
users:
- name: system:kube-scheduler
  user:
    client-certificate-data: $( openssl base64 -A -in ${master_dir}/pki/kube-scheduler.crt ) 
    client-key-data: $( openssl base64 -A -in ${master_dir}/pki/kube-scheduler.key ) 
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: system:kube-scheduler
  name: system:kube-scheduler@${CLUSTER_NAME}
current-context: system:kube-scheduler@${CLUSTER_NAME}
EOF

    echo "Generating kubeconfig for Cluster Admin"
    cat > ${master_dir}/auth/admin.conf << EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: https://${master}.${BASE_DOMAIN}:6443
    certificate-authority-data: $( openssl base64 -A -in $CA_CERT ) 
users:
- name: k8s-admin
  user:
    client-certificate-data: $( openssl base64 -A -in ${master_dir}/pki/apiserver-kubelet-client.crt ) 
    client-key-data: $( openssl base64 -A -in ${master_dir}/pki/apiserver-kubelet-client.key ) 
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: k8s-admin
  name: k8s-admin@${CLUSTER_NAME}
current-context: k8s-admin@${CLUSTER_NAME}
EOF
done

# Generate key and cert for kubelet
kubelet_dir=${DIR}/kubelet
mkdir -p ${kubelet_dir}/{pki,auth}

openssl_req ${kubelet_dir}/pki kube-proxy "/CN=system:kube-proxy"
openssl_sign $CA_CERT $CA_KEY ${kubelet_dir}/pki kube-proxy client_cert
rm -f ${kubelet_dir}/pki/kube-proxy.csr

# Copy the CA cert
cp $CA_CERT ${kubelet_dir}/pki/ 

cat > ${kubelet_dir}/auth/kube-proxy.conf << EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: https://${CLUSTER_NAME}-api.${BASE_DOMAIN}:6443
    certificate-authority-data: $( openssl base64 -A -in $CA_CERT ) 
users:
- name: system:kube-proxy
  user:
    client-certificate-data: $( openssl base64 -A -in ${kubelet_dir}/pki/kube-proxy.crt ) 
    client-key-data: $( openssl base64 -A -in ${kubelet_dir}/pki/kube-proxy.key ) 
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: system:kube-proxy
  name: system:kube-proxy@${CLUSTER_NAME}
current-context: system:kube-proxy@${CLUSTER_NAME}
EOF

# Generate key and cert for ingress
ingress_dir=${DIR}/ingress
mkdir -p ${DIR}/ingress/patches

openssl_req ${ingress_dir} ingress-server "/CN=${CLUSTER_NAME}.${BASE_DOMAIN}"
openssl_sign $CA_CERT $CA_KEY ${ingress_dir} ingress-server server_cert
rm -f ${ingress_dir}/*.csr

# Generate secret patches. We include the metadata here so
# `kubectl patch -f ( file ) -p $( cat ( file ) )` works.
cat > ${ingress_dir}/patches/ingress-tls.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ingress-tls-secret
  namespace: kube-system
data:
  tls.crt: $( openssl base64 -A -in ${ingress_dir}/ingress-server.crt )
  tls.key: $( openssl base64 -A -in ${ingress_dir}/ingress-server.key )
EOF

# Clean up openssl config
rm -f $CERT_DIR/index*
rm -f $CERT_DIR/100*
rm -f $CERT_DIR/serial*
