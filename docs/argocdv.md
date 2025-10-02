# Deploy ArgoCD with olm

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
