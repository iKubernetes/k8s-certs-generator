#!/bin/bash -e

function usage() {
    >&2 cat << EOF
Usage: ./k8s-certs-gen.sh

Set the following environment variables to run this script:

    BASE_DOMAIN     Base domain name of the cluster. For example if your API
                    server is running on "my-cluster-k8s.example.com", the
                    base domain is "example.com"

    CLUSTER_NAME    Name of the cluster. If your API server is running on the
                    domain "my-cluster-k8s.example.com", the name of the cluster
                    is "my-cluster"

    APISERVER_CLUSTER_IP
                    Cluster IP address of the "kubernetes" service in the
                    "default" namespace.

    CA_CERT         Path to the pem encoded CA certificate of your cluster.
    CA_KEY          Path to the pem encoded CA key of your cluster.
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

export DIR="generated"
if [ $# -eq 1 ]; then
    DIR="$1"
fi

export CERT_DIR=$DIR/pki
mkdir -p $CERT_DIR
PATCHES=$DIR/patches
mkdir -p $PATCHES
mkdir -p $DIR/auth

if [ -z "$CA_CERT" -o -z "$CA_KEY" ]; then
    openssl genrsa -out $CERT_DIR/ca.key 4096
    openssl req -config openssl.conf \
        -new -x509 -days 3650 -sha256 \
        -key $CERT_DIR/ca.key -out $CERT_DIR/ca.crt \
	-subj "/CN=k8s-ca"
    export CA_KEY=$CERT_DIR/ca.key
    export CA_CERT=$CERT_DIR/ca.crt
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

# Generate CSRs for all components
openssl_req $CERT_DIR apiserver "/CN=kube-apiserver/O=kube-master"
#openssl_req $CERT_DIR kubelet "/CN=kubelet/O=system:masters"
openssl_req $CERT_DIR kube-proxy "/CN=system:kube-proxy/O=kube-nodes"
openssl_req $CERT_DIR ingress-server "/CN=${CLUSTER_NAME}.${BASE_DOMAIN}"

# Sign CSRs for all components
openssl_sign $CA_CERT $CA_KEY $CERT_DIR apiserver apiserver_cert
#openssl_sign $CA_CERT $CA_KEY $CERT_DIR kubelet client_cert
openssl_sign $CA_CERT $CA_KEY $CERT_DIR kube-proxy client_cert
openssl_sign $CA_CERT $CA_KEY $CERT_DIR ingress-server server_cert


# Add debug information to directories
for CERT in $CERT_DIR/*.crt; do
    openssl x509 -in $CERT -noout -text > "${CERT%.crt}.txt"
done

# Use openssl for base64'ing instead of base64 which has different wrap behavior
# between Linux and Mac.
# https://stackoverflow.com/questions/46463027/base64-doesnt-have-w-option-in-mac 
cat > $DIR/auth/kubeconfig << EOF
apiVersion: v1
kind: Config
clusters:
- name: my-cluster
  cluster:
    server: https://${CLUSTER_NAME}-api.${BASE_DOMAIN}:443
    certificate-authority-data: $( openssl base64 -A -in $CA_CERT ) 
users:
- name: kubelet
  user:
    client-certificate-data: $( openssl base64 -A -in $CERT_DIR/kubelet.crt ) 
    client-key-data: $( openssl base64 -A -in $CERT_DIR/kubelet.key ) 
contexts:
- context:
    cluster: my-cluster
    user: kubelet
EOF

# Generate secret patches. We include the metadata here so
# `kubectl patch -f ( file ) -p $( cat ( file ) )` works.
cat > $PATCHES/ingress-tls.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: tectonic-ingress-tls-secret
  namespace: tectonic-system
data:
  tls.crt: $( openssl base64 -A -in ${CERT_DIR}/ingress-server.crt )
  tls.key: $( openssl base64 -A -in ${CERT_DIR}/ingress-server.key )
EOF

cat > $PATCHES/kube-apiserver-secret.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  apiserver.crt: $( openssl base64 -A -in ${CERT_DIR}/apiserver.crt )
  apiserver.key: $( openssl base64 -A -in ${CERT_DIR}/apiserver.key )
EOF

# If supplied, generate a new etcd CA and associated certs.
if [ -n $FRONT_PROXY_CA_CERT ]; then
    openssl genrsa -out $CERT_DIR/front-proxy-ca.key 2048
    openssl req -config openssl.conf \
        -new -x509 -days 3650 -sha256 \
        -key $CERT_DIR/front-proxy-ca.key \
        -out $CERT_DIR/front-proxy-ca.crt -subj "/CN=front-proxy-ca"
    
    openssl_req $CERT_DIR front-proxy-client "/CN=front-proxy-client"
    
    openssl_sign $CERT_DIR/front-proxy-ca.crt $CERT_DIR/front-proxy-ca.key $CERT_DIR front-proxy-client client_cert

    # Add debug information to directories
    for CERT in $CERT_DIR/front-proxy-*.crt; do
        openssl x509 -in $CERT -noout -text > "${CERT%.crt}.txt"
    done
fi

# Clean up openssl config
rm $CERT_DIR/index*
rm $CERT_DIR/100*
rm $CERT_DIR/serial*
rm $CERT_DIR/*.csr
