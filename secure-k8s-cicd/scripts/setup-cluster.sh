#!/bin/bash
# setup-cluster.sh - Complete cluster setup script

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    commands=("kubectl" "helm" "docker")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error "$cmd is not installed or not in PATH"
        fi
    done
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        error "kubectl cannot connect to cluster"
    fi
    
    log "Prerequisites check passed"
}

# Setup namespaces
setup_namespaces() {
    log "Setting up namespaces..."
    
    namespaces=("jenkins" "messaging" "production" "staging" "monitoring")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" &> /dev/null; then
            warn "Namespace $ns already exists"
        else
            kubectl create namespace "$ns"
            kubectl label namespace "$ns" name="$ns"
            log "Created namespace: $ns"
        fi
    done
}

# Install cert-manager
install_cert_manager() {
    log "Installing cert-manager..."
    
    if helm list -n cert-manager | grep -q cert-manager; then
        warn "cert-manager already installed"
    else
        helm repo add jetstack https://charts.jetstack.io
        helm repo update
        
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.crds.yaml
        
        helm install cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --create-namespace \
            --version v1.13.0 \
            --set installCRDs=true
        
        log "cert-manager installed successfully"
    fi
}

# Deploy RabbitMQ
deploy_rabbitmq() {
    log "Deploying RabbitMQ..."
    
    if kubectl get deployment rabbitmq -n messaging &> /dev/null; then
        warn "RabbitMQ already deployed"
    else
        kubectl apply -f k8s/rabbitmq-deployment.yaml
        kubectl wait --for=condition=available --timeout=300s deployment/rabbitmq -n messaging
        log "RabbitMQ deployed successfully"
    fi
}

# Deploy Jenkins
deploy_jenkins() {
    log "Deploying Jenkins..."
    
    if kubectl get deployment jenkins -n jenkins &> /dev/null; then
        warn "Jenkins already deployed"
    else
        kubectl apply -f k8s/jenkins-deployment.yaml
        kubectl wait --for=condition=available --timeout=600s deployment/jenkins -n jenkins
        log "Jenkins deployed successfully"
        
        # Get Jenkins admin password
        JENKINS_PASSWORD=$(kubectl get secret jenkins-secret -n jenkins -o jsonpath="{.data.admin-password}" | base64 --decode)
        log "Jenkins admin password: $JENKINS_PASSWORD"
    fi
}

# Main execution
main() {
    log "Starting Kubernetes security cluster setup..."
    
    check_prerequisites
    setup_namespaces
    install_cert_manager
    deploy_rabbitmq
    deploy_jenkins
    
    log "Cluster setup completed successfully!"
}

# Run main function
main "$@"
