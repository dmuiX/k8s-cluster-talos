#!/bin/bash

if [ kubectl version ]; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
fi

kubectl create secret generic cloudflare-token -n cert-manager --from-literal=token=$CLOUDFLARE_TOKEN
kubectl create secret generic pihole -n external-dns --from-literal=EXTERNAL_DNS_PIHOLE_PASSWORD=$PIHOLE_PASSWORD --from-literal=EXTERNAL_DNS_PIHOLE_SERVER=$PIHOLE_SERVER --from-literal=EXTERNAL_DNS_PIHOLE_API_VERSION="6"

if [ flux --version ]; then
  curl -s https://fluxcd.io/install.sh | sudo bash
  . <(flux completion zsh)
fi

flux bootstrap github \
  --token-auth \
  --owner=dmuiX \
  --repository=fluxcd.k8sdev.cloud \
  --branch=main \
  --path=clusters \
  --personal \
  --private=true
