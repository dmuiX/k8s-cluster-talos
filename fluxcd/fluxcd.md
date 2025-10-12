# install and configure fluxcd

curl -s https://fluxcd.io/install.sh | sudo bash

. <(flux completion zsh)

 export GITHUB_TOKEN=github_pat_

flux bootstrap github \
  --token-auth \
  --owner=dmuiX \
  --repository=fluxcd.k8sdev.cloud \
  --branch=main \
  --path=clusters \
  --personal \
  --private=true
