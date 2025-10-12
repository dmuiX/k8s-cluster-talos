
# --- Define your repository details ---
#in .env or .envrc file!

SECRET_NAME="github-creds"
NAMESPACE="argocd"
REPO_URL="https://github.com/my-org/my-private-repo.git"
USERNAME="my-github-username"
PASSWORD="my-github-personal-access-token"

# Create, label, and apply the secret in one command
kubectl create secret generic "$SECRET_NAME" \
  --namespace="$NAMESPACE" \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$USERNAME" \
  --from-literal=password="$PASSWORD" \
  --dry-run=client -o yaml | \
kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" -o yaml | \
kubectl apply -f -