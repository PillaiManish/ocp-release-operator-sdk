#!/usr/bin/env bash

source hack/lib/common.sh

set -eux

component="osdk-helm-e2e"
eval IMAGE=$IMAGE_FORMAT
ROOTDIR="$(pwd)"
GOTMP="$(mktemp -d -p $GOPATH/src)"
trap_add 'rm -rf $GOTMP' EXIT

mkdir -p $ROOTDIR/bin
export PATH=$ROOTDIR/bin:$PATH

# Install kubectl client
if ! [ -x "$(command -v kubectl)" ]; then
    curl -Lo kubectl https://storage.googleapis.com/kubernetes-release/release/v1.21.2/bin/linux/amd64/kubectl && chmod +x kubectl && mv kubectl bin/
fi

# Install oc client
if ! [ -x "$(command -v oc)" ]; then
    curl -Lo oc.tar.gz https://github.com/openshift/origin/releases/download/v3.11.0/openshift-origin-client-tools-v3.11.0-0cbc58b-linux-64bit.tar.gz
    tar xvzOf oc.tar.gz openshift-origin-client-tools-v3.11.0-0cbc58b-linux-64bit/oc > oc && chmod +x oc && mv oc bin/ && rm oc.tar.gz
fi

# Printout where we're at and what we're using
oc version
echo $ROOTDIR

# install operator-sdk
if [ -z "$(GOBIN)" ]; then
    export GOBIN=${GOPATH}/bin
fi
make install

# Test the operator
test_operator() {
    echo "Entered test_operator"

    # wait for operator pod to run
    if ! timeout 1m kubectl rollout status deployment/memcached-operator-controller-manager -n memcached-operator-system;
    then
        echo FAIL: for operator pod to run
        kubectl describe pods
        kubectl logs deployment/memcached-operator-controller-manager -c manager
        exit 1
    fi

    # verify that metrics service was created
    if ! timeout 60s bash -c -- "until kubectl get service/memcached-operator-controller-manager-metrics-service > /dev/null 2>&1; do sleep 1; done";
    then
        echo "Failed to get metrics service"
        kubectl describe pods
        kubectl logs deployment/memcached-operator-controller-manager -c manager
        exit 1
    fi

    # create the service-account-token for the default service account
    cat <<EOF | kubectl apply -n memcached-operator-system -f -
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: service-account-secret
  annotations:
    kubernetes.io/service-account.name: "default"
EOF

    # get the serviceaccount token to access the metrics
    token=$(kubectl get secret service-account-secret -o jsonpath={.data.token} | base64 -d)

    # verify that the metrics endpoint exists
    if ! timeout 1m bash -c -- "until kubectl run --attach --rm --restart=Never test-metrics --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -n memcached-operator-system --overrides='{\"spec\":{\"securityContext\":{\"runAsNonRoot\": true, \"capabilities\": {\"drop\": [\"ALL\"]}, \"allowPrivelegeEscalation\": false, \"seccompProfile\": {\"type\": \"RuntimeDefault\"}}}}' -- curl -sfkH \"Authorization: Bearer ${token}\" https://memcached-operator-controller-manager-metrics-service:8443/metrics; do sleep 1; done";
    then
        echo "Failed to verify that metrics endpoint exists"
        kubectl describe pods
        kubectl logs deployment/memcached-operator-controller-manager -c manager
        exit 1
    fi

    # create CR; this will trigger the reconcile and deploy memcached operand
    kubectl apply -f config/samples/cache_v1alpha1_memcached.yaml

    # wait until the statefulset shows up
    if ! timeout 600s bash -c -- 'until kubectl get statefulset memcached-sample; do sleep 1; done';
    then
        echo "Failed to create CR"
        kubectl describe pods
        kubectl logs deployment/memcached-operator-controller-manager -c manager
        kubectl describe statefulsets
        exit 1
    fi

    # wait until the statefulset rollout successfully
    if ! timeout 600s kubectl rollout status statefulset/memcached-sample;
    then
        echo FAIL: to rollout status statefulset
        kubectl describe pods
        kubectl describe deployments
        kubectl logs deployment/memcached-operator-controller-manager -c manager
        kubectl describe statefulsets
        exit 1
    fi

    # Get the memcached sample service
    kubectl get service memcached-sample

    # TODO: revisit the replica portions of the test
    #
    # # scale deployment replicas to 2 and verify the
    # # deployment automatically scales back down to 1.
    # kubectl scale deployment/${memcached_deployment} --replicas=2
    # if ! timeout 1m bash -c -- "until test \$(kubectl get deployment/${memcached_deployment} -o jsonpath='{..spec.replicas}') -eq 1; do sleep 1; done";
    # then
    #     echo FAIL: to scale deployment replicas to 2 and verify the
    #     kubectl describe pods -l "app.kubernetes.io/instance=${release_name}"
    #     kubectl describe deployments ${memcached_deployment}
    #     kubectl logs deployment/memcached-operator-controller-manager -c manager
    #     exit 1
    # fi
    #
    # # update CR to replicaCount=2 and verify the deployment
    # # automatically scales up to 2 replicas.
    # kubectl patch memcachedes.helm.example.com example-memcached -p '[{"op":"replace","path":"/spec/replicaCount","value":2}]' --type=json
    # if ! timeout 1m bash -c -- "until test \$(kubectl get deployment/${memcached_deployment} -o jsonpath='{..spec.replicas}') -eq 2; do sleep 1; done";
    # then
    #     echo FAIL: to update CR to replicaCount=2 and verify the deployment
    #     kubectl describe pods -l "app.kubernetes.io/instance=${release_name}"
    #     kubectl describe deployments ${memcached_deployment}
    #     kubectl logs deployment/memcached-operator-controller-manager -c manager
    #     exit 1
    # fi

    # kubectl delete -f deploy/crds/helm.example.com_v1alpha1_memcached_cr.yaml --wait=true
    kubectl delete -f config/samples/cache_v1alpha1_memcached.yaml --wait=true
    kubectl logs deployment/memcached-operator-controller-manager -c manager | grep "Uninstalled release" | grep "memcached-sample"
}

# use sample in testdata
pushd $ROOTDIR/testdata/helm/memcached-operator
ls

# Give the serviceaccount cluster role to create statefulsets
if oc api-versions | grep openshift; then
    oc adm policy add-cluster-role-to-user cluster-admin -z default || :
fi

# deploy operator
echo "running make deploy"
make deploy IMG=$IMAGE

# create clusterrolebinding for metrics
kubectl create clusterrolebinding memcached-operator-metrics-reader-rolebinding --clusterrole=memcached-operator-metrics-reader --serviceaccount=memcached-operator-system:default

# switch to the "memcached-operator-system" namespace
oc project memcached-operator-system

# Test the operator
echo "running test_operator"
test_operator

# clean up the clusterrolebinding for metrics
kubectl delete clusterrolebinding memcached-operator-metrics-reader-rolebinding

# remove_operator
echo "running make undeploy"
make undeploy

# the memcached-operator pods remain after the deployment is gone; wait until the pods are removed
if ! timeout 60s bash -c -- "until kubectl get pods -l control-plane=controller-manager |& grep \"No resources found\"; do sleep 2; done";
then
    echo FAIL: memcached-operator Deployment did not get garbage collected
    kubectl describe pods
    kubectl describe deployments
    kubectl logs deployment/memcached-operator-controller-manager -c manager
    exit 1
fi

popd
