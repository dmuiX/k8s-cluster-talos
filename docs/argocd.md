# argocd stuff

## install argocd

install argocd crds

`k -n argocd apply -f https://raw.githubusercontent.com/argoproj/argo-cd/master/manifests/ha/namespace-install.yaml`
`k -n argocd apply -f https://raw.githubusercontent.com/argoproj/argo-cd/master/manifests/ha/install.yaml`

install gateway rpcs

`k apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install`

## Add repo

 k create secret generic github-creds -n argocd --from-literal=name=github-repo --from-literal=type="git" --from-literal=url="https://github.com/dmuiX/argocd.k8sdev.cloud.git"  --from-literal=username="dmuiX" --from-literal=password="github_pat_1" --dry-run=client -o yaml | kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" -o yaml | kubectl apply -f -


 k create secret generic github-creds -n argocd --from-literal=type="git" --from-literal=url="https://github.com/dmuiX/argocd.k8sdev.cloud.git"  --from-literal=username="dmuiX" --from-literal=password="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" --dry-run=client -o yaml | kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" -o yaml | kubectl apply -f -
## Add github repository to argocd

```bash
k apply -f argocd/deployment.yml

k create secret generic github-creds -n argocd --from-literal=username=dmuiX --from-literal=token=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

kubectl label secret github-creds -n argocd argocd.argoproj.io/secret-type=repository                          ─╯

kubectl patch secret github-creds -n argocd --type='merge' -p='{"stringData":{"type":"git","url":"https://github.com/dmuiX/argocd.k8sdev.cloud.git"}}'
```

## Deploy ArgoCD with olm

Firt install olm:

seems crds of v0.30.0 are broken

```
k apply -f https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.30.0/crds.yaml
customresourcedefinition.apiextensions.k8s.io/catalogsources.operators.coreos.com created
customresourcedefinition.apiextensions.k8s.io/installplans.operators.coreos.com created
customresourcedefinition.apiextensions.k8s.io/olmconfigs.operators.coreos.com created
customresourcedefinition.apiextensions.k8s.io/operatorconditions.operators.coreos.com created
customresourcedefinition.apiextensions.k8s.io/operatorgroups.operators.coreos.com created
customresourcedefinition.apiextensions.k8s.io/operators.operators.coreos.com created
customresourcedefinition.apiextensions.k8s.io/subscriptions.operators.coreos.com created
The CustomResourceDefinition "clusterserviceversions.operators.coreos.com" is invalid: metadata.annotations: Too long: must have at most 262144 bytes
```
therefore using

using operator-sdk works:
installs v0.28.0
maybe you could also use v0.28.0 from github

```
brew install operator-sdk

operator-sdk olm install 
https://olm.operatorframework.io/docs/getting-started/
https://sdk.operatorframework.io/docs/installation/

```

https://argocd-operator.readthedocs.io/en/latest/install/olm/

```
kubectl get ns
kubectl get pods -n olm
kubectl create namespace argocd

k create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: argocd-catalog
  namespace: olm
spec:
  sourceType: grpc
  image: quay.io/argoprojlabs/argocd-operator-registry@sha256:dcf6d07ed5c8b840fb4a6e9019eacd88cd0913bc3c8caa104d3414a2e9972002 # replace with your index image
  displayName: Argo CD Operators
  publisher: Argo CD Community
EOF

k create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: argocd-operator
  namespace: argocd
EOF

kubectl create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: argocd-operator
  namespace: argocd
spec:
  channel: stable
  name: argocd-operator
  source: argocd-catalog
  sourceNamespace: olm
EOF

```

verify everything works

```
kubectl get subscriptions -n argocd
kubectl get installplans -n argocd
kubectl get pods -n argocd
```

now you can setup a argocd manifest

```bash

k apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ArgoCD
metadata:
  name: argocd
  namespace: argocd
spec:
  server:
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: cilium
        cert-manager.io/cluster-issuer: letsencrypt-prod
        external-dns.alpha.kubernetes.io/hostname: argocd.virtual-lab.pro
        ingress.cilium.io/tls-passthrough: enabled
        ingress.cilium.io/force-https: enabled
      hosts:
        - argocd.virtual-lab.pro
      tls:
        - secretName: argocd-tls
          hosts:
            - argocd.virtual-lab.pro
  prometheus:
    enabled: true
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
EOF
```
