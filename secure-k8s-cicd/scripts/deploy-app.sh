#!/bin/bash
# deploy-app.sh - Application deployment script

set -euo pipefail

NAMESPACE="production"
IMAGE_TAG="${1:-latest}"
HELM_CHART="./helm/my-app"

log() {
    echo -e "\033[0;32m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

error() {
    echo -e "\033[0;31m[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1\033[0m"
    exit 1
}

# Validate image exists
validate_image() {
    log "Validating image: ghcr.io/your-org/my-app:$IMAGE_TAG"
    
    if ! docker manifest inspect "ghcr.io/your-org/my-app:$IMAGE_TAG" &> /dev/null; then
        error "Image ghcr.io/your-org/my-app:$IMAGE_TAG not found"
    fi
    
    log "Image validation passed"
}

# Deploy with Helm
deploy_helm() {
    log "Deploying application with Helm..."
    
    helm upgrade --install my-app "$HELM_CHART" \
        --namespace "$NAMESPACE" \
        --set image.tag="$IMAGE_TAG" \
        --set environment="$NAMESPACE" \
        --wait \
        --timeout=600s
    
    log "Helm deployment completed"
}

# Main deployment function
main() {
    log "Starting application deployment..."
    log "Image tag: $IMAGE_TAG"
    log "Namespace: $NAMESPACE"
    
    validate_image
    deploy_helm
    
    log "Application deployment completed successfully!"
}

main "$@"
