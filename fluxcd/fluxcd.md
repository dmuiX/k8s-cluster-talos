# install and configure fluxcd

curl -s https://fluxcd.io/install.sh | sudo bash

. <(flux completion zsh)

 export GITHUB_TOKEN=github_pat_

flux bootstrap github \
  --token-auth \
  --owner=$GITHUB_REPO_OWNER \
  --repository=fluxcd.k8sdev.cloud \
  --branch=main \
  --path=clusters \
  --personal \
  --private=true

## github permossions fluxcd repo

Für FluxCD Bootstrap auf einem private repo brauchst du:

Contents: Read & Write (Flux pusht seine Manifeste ins Repo)
Metadata: Read (immer required)
Wenn du auch Webhooks willst (damit Flux bei Push sofort reconciled):

Webhooks: Read & Write
Das war's. Kein Admin, kein Actions, nix anderes.

