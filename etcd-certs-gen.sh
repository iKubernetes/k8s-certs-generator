#!/bin/bash -e

function usage() {
    >&2 cat << EOF
Usage: ./etcd-certs-gen.sh

Set the following environment variables to run this script:

    BASE_DOMAIN     Base domain name of the cluster. For example if your API
                    server is running on "my-cluster-k8s.example.com", the
                    base domain is "example.com"

    CA_CERT(optional)         Path to the pem encoded CA certificate of your cluster.
    CA_KEY(optional)          Path to the pem encoded CA key of your cluster.
EOF
    exit 1
}

if [ -z $BASE_DOMAIN ]; then
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

if [ -z "$CA_KEY" -o -z "$CA_CERT" ]; then
    openssl genrsa -out $CERT_DIR/ca.key 4096
    openssl req -config openssl.conf \
        -new -x509 -days 3650 -sha256 \
        -key $CERT_DIR/ca.key -extensions v3_ca \
        -out $CERT_DIR/ca.crt -subj "/CN=etcd-ca"
    export CA_KEY="$CERT_DIR/ca.key"
    export CA_CERT="$CERT_DIR/ca.crt"
fi

openssl_req $CERT_DIR peer "/CN=etcd"
openssl_req $CERT_DIR server "/CN=etcd"
openssl_req $CERT_DIR client "/CN=etcd"
    
openssl_sign $CERT_DIR/ca.crt $CERT_DIR/ca.key $CERT_DIR peer etcd_peer_cert
openssl_sign $CERT_DIR/ca.crt $CERT_DIR/ca.key $CERT_DIR server etcd_server_cert
openssl_sign $CERT_DIR/ca.crt $CERT_DIR/ca.key $CERT_DIR client client_cert

cat $CERT_DIR/ca.crt > $CERT_DIR/ca_bundle.pem
cat $CA_CERT >> $CERT_DIR/ca_bundle.pem

# Add debug information to directories
for CERT in $CERT_DIR/*.crt; do
    openssl x509 -in $CERT -noout -text > "${CERT%.crt}.txt"
done

ETCD_PATCHES=$DIR/patches
mkdir -p $ETCD_PATCHES

# kubectl apply 
cat > $ETCD_PATCHES/etcd-ca.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  etcd-client-ca.crt: $( openssl base64 -A -in ${ETCD}/ca_bundle.pem )
EOF

cat > $ETCD_PATCHES/etcd-client-cert.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  etcd-client.crt: $( openssl base64 -A -in ${CERT_DIR}/client.crt )
  etcd-client.key: $( openssl base64 -A -in ${CERT_DIR}/client.key )
EOF

# Clean up openssl config
rm $CERT_DIR/index*
rm $CERT_DIR/100*
rm $CERT_DIR/serial*
rm $CERT_DIR/*.csr
