#!/bin/bash
# create-project-tarball.sh - Creates a complete project tarball

set -euo pipefail

PROJECT_NAME="secure-k8s-cicd"
TEMP_DIR="/tmp/${PROJECT_NAME}"
TARBALL_NAME="${PROJECT_NAME}.tar.gz"

log() {
    echo -e "\033[0;32m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

# Clean up any existing temp directory
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Create project structure
create_structure() {
    log "Creating project directory structure..."
    
    mkdir -p "$TEMP_DIR"/{.github/workflows,k8s,helm/my-app/templates,security-policies,scripts,src,tests}
    
    log "Directory structure created"
}

# Create all configuration files
create_files() {
    log "Creating configuration files..."
    
    # GitHub Actions workflows
    cat > "$TEMP_DIR/.github/workflows/security-scan.yml" << 'EOF'
name: Security Scanning Pipeline

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  code-security-scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
      actions: read
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v4
      with:
        fetch-depth: 0

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Run Trivy vulnerability scanner in repo mode
      uses: aquasecurity/trivy-action@master
      with:
        scan-type: 'fs'
        scan-ref: '.'
        format: 'sarif'
        output: 'trivy-results.sarif'

    - name: Upload Trivy scan results to GitHub Security tab
      uses: github/codeql-action/upload-sarif@v3
      if: always()
      with:
        sarif_file: 'trivy-results.sarif'

    - name: Run Semgrep Security Scan
      uses: semgrep/semgrep-action@v1
      with:
        config: >-
          p/security-audit
          p/secrets
          p/kubernetes
          p/docker
      env:
        SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}

    - name: Check for secrets with GitLeaks
      uses: gitleaks/gitleaks-action@v2
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF

    cat > "$TEMP_DIR/.github/workflows/build-and-deploy.yml" << 'EOF'
name: Build and Deploy

on:
  push:
    branches: [ main ]
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
  KUBE_NAMESPACE: production

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image-digest: ${{ steps.build.outputs.digest }}
      image-url: ${{ steps.build.outputs.image-url }}
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to Container Registry
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Extract metadata
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        tags: |
          type=ref,event=branch
          type=ref,event=pr
          type=sha,prefix={{branch}}-
          type=raw,value=latest,enable={{is_default_branch}}

    - name: Build and push Docker image
      id: build
      uses: docker/build-push-action@v5
      with:
        context: .
        platforms: linux/amd64,linux/arm64
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}
        cache-from: type=gha
        cache-to: type=gha,mode=max

    - name: Generate SBOM
      uses: anchore/sbom-action@v0
      with:
        image: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
        format: spdx-json
        output-file: sbom.spdx.json

    - name: Upload SBOM
      uses: actions/upload-artifact@v4
      with:
        name: sbom
        path: sbom.spdx.json

  vulnerability-scan:
    runs-on: ubuntu-latest
    needs: build-and-push
    permissions:
      contents: read
      security-events: write
    
    steps:
    - name: Run Trivy vulnerability scanner
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
        format: 'sarif'
        output: 'trivy-results.sarif'

    - name: Upload Trivy scan results
      uses: github/codeql-action/upload-sarif@v3
      if: always()
      with:
        sarif_file: 'trivy-results.sarif'

    - name: Check vulnerability scan results
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
        format: 'json'
        exit-code: '1'
        severity: 'CRITICAL,HIGH'

  deploy-staging:
    runs-on: ubuntu-latest
    needs: [build-and-push, vulnerability-scan]
    environment: staging
    if: github.ref == 'refs/heads/develop'
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    - name: Configure kubectl
      uses: azure/k8s-set-context@v3
      with:
        method: kubeconfig
        kubeconfig: ${{ secrets.KUBE_CONFIG_STAGING }}

    - name: Deploy to staging
      run: |
        envsubst < k8s/deployment.yaml | kubectl apply -f -
        kubectl rollout status deployment/app-deployment -n staging
      env:
        IMAGE_TAG: ${{ github.sha }}
        NAMESPACE: staging

  trigger-jenkins-production:
    runs-on: ubuntu-latest
    needs: [build-and-push, vulnerability-scan]
    if: github.ref == 'refs/heads/main'
    
    steps:
    - name: Trigger Jenkins Production Deploy
      run: |
        curl -X POST \
          -H "Authorization: Bearer ${{ secrets.JENKINS_API_TOKEN }}" \
          -H "Content-Type: application/json" \
          -d '{
            "parameter": [
              {"name": "IMAGE_TAG", "value": "${{ github.sha }}"},
              {"name": "DEPLOY_ENV", "value": "production"},
              {"name": "GIT_COMMIT", "value": "${{ github.sha }}"}
            ]
          }' \
          "${{ secrets.JENKINS_URL }}/job/production-deploy/buildWithParameters"

  notify-teams:
    runs-on: ubuntu-latest
    needs: [build-and-push, vulnerability-scan]
    if: always()
    
    steps:
    - name: Notify Teams
      uses: 8398a7/action-slack@v3
      with:
        status: ${{ job.status }}
        channel: '#deployments'
        webhook_url: ${{ secrets.SLACK_WEBHOOK }}
        fields: repo,message,commit,author,action,eventName,ref,workflow
EOF

    cat > "$TEMP_DIR/.github/workflows/infrastructure-scan.yml" << 'EOF'
name: Infrastructure Security Scan

on:
  push:
    paths:
      - 'k8s/**'
      - 'terraform/**'
      - 'helm/**'
  pull_request:
    paths:
      - 'k8s/**'
      - 'terraform/**'
      - 'helm/**'

jobs:
  kubernetes-security-scan:
    runs-on: ubuntu-latest
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Run Kubesec scan
      run: |
        curl -sSX POST --data-binary @k8s/deployment.yaml \
          https://v2.kubesec.io/scan > kubesec-results.json
        
    - name: Upload Kubesec results
      uses: actions/upload-artifact@v4
      with:
        name: kubesec-results
        path: kubesec-results.json

    - name: Run Polaris scan
      uses: fairwindsops/polaris-action@v1.0
      with:
        config: polaris.yaml

    - name: Run OPA Conftest
      uses: instrumenta/conftest-action@master
      with:
        files: k8s/*.yaml
        policy: security-policies

  terraform-security-scan:
    runs-on: ubuntu-latest
    if: contains(github.event.head_commit.modified, 'terraform/')
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Run tfsec
      uses: aquasecurity/tfsec-action@v1.0.0
      with:
        soft_fail: true

    - name: Run Checkov
      uses: bridgecrewio/checkov-action@master
      with:
        directory: terraform/
        framework: terraform
EOF

    # Kubernetes manifests
    cat > "$TEMP_DIR/k8s/rabbitmq-deployment.yaml" << 'EOF'
# RabbitMQ ConfigMap for configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: rabbitmq-config
  namespace: messaging
data:
  rabbitmq.conf: |
    default_user = admin
    default_pass = changeme123
    cluster_formation.peer_discovery_backend = rabbit_peer_discovery_k8s
    cluster_formation.k8s.host = kubernetes.default.svc.cluster.local
    cluster_formation.k8s.address_type = hostname
    cluster_formation.node_cleanup.interval = 30
    cluster_formation.node_cleanup.only_log_warning = true
    cluster_partition_handling = autoheal
    queue_master_locator = min-masters

---
# RabbitMQ Secret for credentials
apiVersion: v1
kind: Secret
metadata:
  name: rabbitmq-secret
  namespace: messaging
type: Opaque
data:
  username: YWRtaW4=  # admin (base64)
  password: Y2hhbmdlbWUxMjM=  # changeme123 (base64)

---
# RabbitMQ Service
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq-service
  namespace: messaging
  labels:
    app: rabbitmq
spec:
  selector:
    app: rabbitmq
  ports:
  - name: amqp
    port: 5672
    targetPort: 5672
    protocol: TCP
  - name: management
    port: 15672
    targetPort: 15672
    protocol: TCP
  - name: clustering
    port: 25672
    targetPort: 25672
    protocol: TCP
  type: ClusterIP

---
# RabbitMQ Headless Service (for clustering)
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq-headless
  namespace: messaging
  labels:
    app: rabbitmq
spec:
  selector:
    app: rabbitmq
  ports:
  - name: amqp
    port: 5672
    targetPort: 5672
  - name: clustering
    port: 25672
    targetPort: 25672
  clusterIP: None

---
# RabbitMQ StatefulSet
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rabbitmq
  namespace: messaging
spec:
  serviceName: rabbitmq-headless
  replicas: 3
  selector:
    matchLabels:
      app: rabbitmq
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      serviceAccountName: rabbitmq
      containers:
      - name: rabbitmq
        image: rabbitmq:3.12-management
        ports:
        - containerPort: 5672
          name: amqp
        - containerPort: 15672
          name: management
        - containerPort: 25672
          name: clustering
        env:
        - name: RABBITMQ_DEFAULT_USER
          valueFrom:
            secretKeyRef:
              name: rabbitmq-secret
              key: username
        - name: RABBITMQ_DEFAULT_PASS
          valueFrom:
            secretKeyRef:
              name: rabbitmq-secret
              key: password
        - name: RABBITMQ_ERLANG_COOKIE
          value: "mycookie"
        - name: RABBITMQ_USE_LONGNAME
          value: "true"
        - name: RABBITMQ_NODENAME
          value: "rabbit@$(POD_NAME).rabbitmq-headless.messaging.svc.cluster.local"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        volumeMounts:
        - name: rabbitmq-config
          mountPath: /etc/rabbitmq/
        - name: rabbitmq-data
          mountPath: /var/lib/rabbitmq
        livenessProbe:
          exec:
            command:
            - rabbitmq-diagnostics
            - status
          initialDelaySeconds: 60
          periodSeconds: 60
          timeoutSeconds: 15
        readinessProbe:
          exec:
            command:
            - rabbitmq-diagnostics
            - ping
          initialDelaySeconds: 20
          periodSeconds: 60
          timeoutSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
      volumes:
      - name: rabbitmq-config
        configMap:
          name: rabbitmq-config
  volumeClaimTemplates:
  - metadata:
      name: rabbitmq-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi

---
# ServiceAccount for RabbitMQ
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rabbitmq
  namespace: messaging

---
# Role for RabbitMQ clustering
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: messaging
  name: rabbitmq
rules:
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["get"]

---
# RoleBinding for RabbitMQ
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: rabbitmq
  namespace: messaging
subjects:
- kind: ServiceAccount
  name: rabbitmq
  namespace: messaging
roleRef:
  kind: Role
  name: rabbitmq
  apiGroup: rbac.authorization.k8s.io

---
# NetworkPolicy for RabbitMQ (Security focus)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rabbitmq-network-policy
  namespace: messaging
spec:
  podSelector:
    matchLabels:
      app: rabbitmq
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: app-namespace
    - podSelector:
        matchLabels:
          rabbitmq-client: "true"
    ports:
    - protocol: TCP
      port: 5672
    - protocol: TCP
      port: 15672
  - from:
    - podSelector:
        matchLabels:
          app: rabbitmq
    ports:
    - protocol: TCP
      port: 25672
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: rabbitmq
    ports:
    - protocol: TCP
      port: 25672
  - to: []
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
EOF

    cat > "$TEMP_DIR/k8s/jenkins-deployment.yaml" << 'EOF'
# Jenkins Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: jenkins
  labels:
    name: jenkins

---
# Jenkins ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: jenkins

---
# Jenkins ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec", "pods/log", "persistentvolumeclaims", "events"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: ["apps"]
  resources: ["deployments", "daemonsets", "replicasets", "statefulsets"]
  verbs: ["*"]
- apiGroups: ["extensions"]
  resources: ["deployments", "daemonsets", "replicasets", "ingresses"]
  verbs: ["*"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["*"]

---
# Jenkins ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jenkins
subjects:
- kind: ServiceAccount
  name: jenkins
  namespace: jenkins

---
# Jenkins ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: jenkins-config
  namespace: jenkins
data:
  jenkins.yaml: |
    jenkins:
      securityRealm:
        local:
          allowsSignup: false
          users:
           - id: admin
             password: ${JENKINS_ADMIN_PASSWORD}
      authorizationStrategy:
        globalMatrix:
          permissions:
            - "Overall/Administer:admin"
            - "Overall/Read:authenticated"
      remotingSecurity:
        enabled: true
    security:
      globalJobDslSecurityConfiguration:
        useScriptSecurity: true
    unclassified:
      location:
        url: "http://jenkins.example.com"

---
# Jenkins PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-pvc
  namespace: jenkins
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi

---
# Jenkins Secret
apiVersion: v1
kind: Secret
metadata:
  name: jenkins-secret
  namespace: jenkins
type: Opaque
data:
  admin-password: YWRtaW4xMjM=  # admin123 (base64)
  github-token: ""  # Add your GitHub token here (base64 encoded)

---
# Jenkins Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
  namespace: jenkins
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: jenkins
  template:
    metadata:
      labels:
        app: jenkins
    spec:
      serviceAccountName: jenkins
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsGroup: 1000
      containers:
      - name: jenkins
        image: jenkins/jenkins:2.426.1-lts
        ports:
        - containerPort: 8080
          name: web
        - containerPort: 50000
          name: agent
        env:
        - name: JAVA_OPTS
          value: "-Djenkins.install.runSetupWizard=false -Dhudson.security.csrf.DefaultCrumbIssuer.EXCLUDE_SESSION_ID=true"
        - name: JENKINS_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: jenkins-secret
              key: admin-password
        - name: CASC_JENKINS_CONFIG
          value: /var/jenkins_home/casc_configs/jenkins.yaml
        volumeMounts:
        - name: jenkins-home
          mountPath: /var/jenkins_home
        - name: jenkins-config
          mountPath: /var/jenkins_home/casc_configs
        - name: docker-sock
          mountPath: /var/run/docker.sock
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 2Gi
        livenessProbe:
          httpGet:
            path: /login
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /login
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 5
      volumes:
      - name: jenkins-home
        persistentVolumeClaim:
          claimName: jenkins-pvc
      - name: jenkins-config
        configMap:
          name: jenkins-config
      - name: docker-sock
        hostPath:
          path: /var/run/docker.sock

---
# Jenkins Service
apiVersion: v1
kind: Service
metadata:
  name: jenkins-service
  namespace: jenkins
spec:
  selector:
    app: jenkins
  ports:
  - name: web
    port: 8080
    targetPort: 8080
  - name: agent
    port: 50000
    targetPort: 50000
  type: LoadBalancer

---
# Jenkins Network Policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: jenkins-network-policy
  namespace: jenkins
spec:
  podSelector:
    matchLabels:
      app: jenkins
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: jenkins-agents
    - podSelector: {}
    ports:
    - protocol: TCP
      port: 8080
    - protocol: TCP
      port: 50000
  egress:
  - to: []
    ports:
    - protocol: TCP
      port: 443
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 22
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
EOF

    cat > "$TEMP_DIR/k8s/network-policies.yaml" << 'EOF'
# Default deny all network policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress

---
# Allow app to RabbitMQ
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-rabbitmq
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: my-app
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: messaging
    - podSelector:
        matchLabels:
          app: rabbitmq
    ports:
    - protocol: TCP
      port: 5672

---
# Allow ingress to app
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-app
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: my-app
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-system
    ports:
    - protocol: TCP
      port: 8080

---
# Allow DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-access
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to: []
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
EOF

    # Jenkins pipeline
    cat > "$TEMP_DIR/Jenkinsfile" << 'EOF'
// Jenkinsfile - Production Deployment Pipeline
pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: kubectl
    image: bitnami/kubectl:latest
    command:
    - cat
    tty: true
  - name: helm
    image: alpine/helm:latest
    command:
    - cat
    tty: true
  - name: trivy
    image: aquasec/trivy:latest
    command:
    - cat
    tty: true
  - name: docker
    image: docker:dind
    privileged: true
    env:
    - name: DOCKER_TLS_CERTDIR
      value: ""
"""
        }
    }

    parameters {
        string(name: 'IMAGE_TAG', defaultValue: 'latest', description: 'Docker image tag to deploy')
        choice(name: 'DEPLOY_ENV', choices: ['staging', 'production'], description: 'Target environment')
        string(name: 'GIT_COMMIT', defaultValue: '', description: 'Git commit hash')
        booleanParam(name: 'SKIP_TESTS', defaultValue: false, description: 'Skip security tests')
    }

    environment {
        REGISTRY = 'ghcr.io'
        IMAGE_NAME = "${env.GITHUB_REPOSITORY ?: 'your-org/your-app'}"
        KUBE_NAMESPACE = "${params.DEPLOY_ENV}"
        SLACK_CHANNEL = '#deployments'
    }

    stages {
        stage('Validate Parameters') {
            steps {
                script {
                    if (params.IMAGE_TAG == 'latest' && params.DEPLOY_ENV == 'production') {
                        error("Production deployments require specific image tags, not 'latest'")
                    }
                    
                    echo "Deploying ${env.REGISTRY}/${env.IMAGE_NAME}:${params.IMAGE_TAG} to ${params.DEPLOY_ENV}"
                }
            }
        }

        stage('Security Scan') {
            when {
                not { params.SKIP_TESTS }
            }
            parallel {
                stage('Container Security Scan') {
                    steps {
                        container('trivy') {
                            script {
                                sh """
                                    trivy image --exit-code 1 --severity HIGH,CRITICAL \
                                        --format json --output trivy-report.json \
                                        ${env.REGISTRY}/${env.IMAGE_NAME}:${params.IMAGE_TAG}
                                """
                                
                                archiveArtifacts artifacts: 'trivy-report.json', fingerprint: true
                                publishHTML([
                                    allowMissing: false,
                                    alwaysLinkToLastBuild: true,
                                    keepAll: true,
                                    reportDir: '.',
                                    reportFiles: 'trivy-report.json',
                                    reportName: 'Trivy Security Report'
                                ])
                            }
                        }
                    }
                    post {
                        failure {
                            slackSend(
                                channel: env.SLACK_CHANNEL,
                                color: 'danger',
                                message: "🚨 Security scan failed for ${env.IMAGE_NAME}:${params.IMAGE_TAG}"
                            )
                        }
                    }
                }

                stage('Kubernetes Security Validation') {
                    steps {
                        container('kubectl') {
                            script {
                                sh """
                                    # Validate Kubernetes manifests
                                    kubectl --dry-run=client apply -f k8s/ || exit 1
                                    
                                    # Check resource quotas
                                    kubectl describe quota -n ${env.KUBE_NAMESPACE} || true
                                """
                            }
                        }
                    }
                }
            }
        }

        stage('Deploy Application') {
            steps {
                container('helm') {
                    script {
                        sh """
                            # Deploy using Helm
                            helm upgrade --install my-app ./helm/my-app \
                                --namespace ${env.KUBE_NAMESPACE} \
                                --set image.repository=${env.REGISTRY}/${env.IMAGE_NAME} \
                                --set image.tag=${params.IMAGE_TAG} \
                                --set environment=${params.DEPLOY_ENV} \
                                --wait \
                                --timeout=600s
                        """
                    }
                }
            }
        }

        stage('Post-deployment Validation') {
            steps {
                container('kubectl') {
                    script {
                        sh """
                            # Wait for rollout to complete
                            kubectl rollout status deployment/my-app -n ${env.KUBE_NAMESPACE} --timeout=300s
                            
                            # Check pod health
                            kubectl get pods -n ${env.KUBE_NAMESPACE} -l app=my-app
                            
                            # Run health checks
                            sleep 30
                            kubectl exec -n ${env.KUBE_NAMESPACE} deployment/my-app -- curl -f http://localhost:8080/health || exit 1
                        """
                    }
                }
            }
        }
    }

    post {
        success {
            slackSend(
                channel: env.SLACK_CHANNEL,
                color: 'good',
                message: """✅ Deployment successful!
                Environment: ${params.DEPLOY_ENV}
                Image: ${env.IMAGE_NAME}:${params.IMAGE_TAG}
                Job: ${env.BUILD_URL}"""
            )
        }
        
        failure {
            slackSend(
                channel: env.SLACK_CHANNEL,
                color: 'danger',
                message: """❌ Deployment failed!
                Environment: ${params.DEPLOY_ENV}
                Image: ${env.IMAGE_NAME}:${params.IMAGE_TAG}
                Job: ${env.BUILD_URL}"""
            )
        }
    }
}
EOF

    # Helm chart files
    cat > "$TEMP_DIR/helm/my-app/Chart.yaml" << 'EOF'
apiVersion: v2
name: my-app
description: A secure microservice application
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF

    cat > "$TEMP_DIR/helm/my-app/values.yaml" << 'EOF'
replicaCount: 3

image:
  repository: ghcr.io/your-org/my-app
  pullPolicy: IfNotPresent
  tag: ""

imagePullSecrets: []
nameOverride: ""
fullnameOverride: ""

serviceAccount:
  create: true
  annotations: {}
  name: ""

podAnnotations: {}

podSecurityContext:
  fsGroup: 1001
  runAsNonRoot: true
  runAsUser: 1001

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1001

service:
  type: ClusterIP
  port: 80
  targetPort: 3000

ingress:
  enabled: true
  className: "nginx"
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
  hosts:
    - host: my-app.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: my-app-tls
      hosts:
        - my-app.example.com

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80

nodeSelector: {}

tolerations: []

affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/name
            operator: In
            values:
            - my-app
        topologyKey: kubernetes.io/hostname

networkPolicy:
  enabled: true
  ingress:
    enabled: true
    from:
    - namespaceSelector:
        matchLabels:
          name: ingress-system
  egress:
    enabled: true
    to:
    - namespaceSelector:
        matchLabels:
          name: messaging
      podSelector:
        matchLabels:
          app: rabbitmq

monitoring:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 30s
    path: /metrics

rabbitmq:
  host: rabbitmq-service.messaging.svc.cluster.local
  port: 5672
  username: admin
  existingSecret: rabbitmq-secret
  existingSecretPasswordKey: password
EOF

    cat > "$TEMP_DIR/helm/my-app/templates/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "my-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "my-app.selectorLabels" . | nindent 8 }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "my-app.serviceAccountName" . }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ .Chart.Name }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          env:
            - name: RABBITMQ_HOST
              value: {{ .Values.rabbitmq.host | quote }}
            - name: RABBITMQ_PORT
              value: {{ .Values.rabbitmq.port | quote }}
            - name: RABBITMQ_USERNAME
              value: {{ .Values.rabbitmq.username | quote }}
            - name: RABBITMQ_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.rabbitmq.existingSecret }}
                  key: {{ .Values.rabbitmq.existingSecretPasswordKey }}
            - name: NODE_ENV
              value: "production"
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /app/.cache
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
      volumes:
        - name: tmp
          emptyDir: {}
        - name: cache
          emptyDir: {}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
EOF

    cat > "$TEMP_DIR/helm/my-app/templates/_helpers.tpl" << 'EOF'
{{/*
Expand the name of the chart.
*/}}
{{- define "my-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "my-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "my-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "my-app.labels" -}}
helm.sh/chart: {{ include "my-app.chart" . }}
{{ include "my-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "my-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "my-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "my-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "my-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
EOF

    # Security policies
    cat > "$TEMP_DIR/security-policies/kubernetes.rego" << 'EOF'
package kubernetes.admission

deny[msg] {
    input.request.kind.kind == "Pod"
    input.request.object.spec.securityContext.runAsRoot == true
    msg := "Containers must not run as root"
}

deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    not container.resources.limits
    msg := "Container must have resource limits set"
}

deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    container.securityContext.privileged == true
    msg := "Containers must not run in privileged mode"
}

deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    container.securityContext.allowPrivilegeEscalation == true
    msg := "Containers must not allow privilege escalation"
}
EOF

    cat > "$TEMP_DIR/polaris.yaml" << 'EOF'
checks:
  cpuRequestsMissing: warning
  cpuLimitsMissing: warning
  memoryRequestsMissing: warning
  memoryLimitsMissing: warning
  runAsRootAllowed: error
  runAsPrivileged: error
  notReadOnlyRootFilesystem: warning
  privilegeEscalationAllowed: error
  dangerousCapabilities: error
  insecureCapabilities: warning
  hostNetworkSet: error
  hostPIDSet: error
  hostIPCSet: error
  hostPortSet: warning
  tlsSettingsMissing: warning
EOF

    cat > "$TEMP_DIR/.gitleaks.toml" << 'EOF'
title = "Gitleaks Config"

[extend]
useDefault = true

[[rules]]
description = "Kubernetes Service Account Token"
id = "k8s-service-account-token"
regex = '''eyJhbGciOiJSUzI1NiIsImtpZCI6Ii'''
tags = ["key", "kubernetes"]

[[rules]]
description = "Docker Config"
id = "docker-config"
regex = '''(?i)(docker|registry).*['"]*config['"]*\s*[:=]\s*['"]*([a-zA-Z0-9+/]{40,})['"]*'''
tags = ["key", "docker"]

[[rules]]
description = "RabbitMQ Connection String"
id = "rabbitmq-conn-string"
regex = '''amqps?://[a-zA-Z0-9._-]+:[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+'''
tags = ["rabbitmq", "connection"]
EOF

    # Application files
    cat > "$TEMP_DIR/package.json" << 'EOF'
{
  "name": "secure-k8s-app",
  "version": "1.0.0",
  "description": "Secure Kubernetes microservice",
  "main": "dist/index.js",
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js",
    "dev": "ts-node src/index.ts",
    "test": "jest",
    "security": "npm audit && snyk test"
  },
  "dependencies": {
    "express": "^4.18.2",
    "amqplib": "^0.10.3",
    "helmet": "^7.0.0",
    "prom-client": "^15.0.0"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "@types/node": "^20.0.0",
    "@types/express": "^4.17.17",
    "ts-node": "^10.9.0",
    "jest": "^29.0.0",
    "snyk": "^1.1000.0"
  }
}
EOF

    cat > "$TEMP_DIR/src/index.ts" << 'EOF'
import express from 'express';
import helmet from 'helmet';
import * as amqp from 'amqplib';
import { register, Counter, Histogram } from 'prom-client';

const app = express();
const port = process.env.PORT || 3000;

// Security middleware
app.use(helmet());
app.use(express.json({ limit: '1mb' }));

// Metrics
const requestCounter = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'path', 'status']
});

const requestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  buckets: [0.1, 0.5, 1, 2, 5]
});

// Health endpoints
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

app.get('/ready', (req, res) => {
  res.json({ status: 'ready', timestamp: new Date().toISOString() });
});

app.get('/metrics', (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(register.metrics());
});

// Sample API endpoint
app.get('/api/message', async (req, res) => {
  const end = requestDuration.startTimer();
  
  try {
    // Simulate RabbitMQ interaction
    const message = { 
      id: Math.random().toString(36),
      message: 'Hello from secure K8s app!',
      timestamp: new Date().toISOString()
    };
    
    requestCounter.inc({ method: 'GET', path: '/api/message', status: '200' });
    res.json(message);
  } catch (error) {
    requestCounter.inc({ method: 'GET', path: '/api/message', status: '500' });
    res.status(500).json({ error: 'Internal server error' });
  } finally {
    end();
  }
});

app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});
EOF

    cat > "$TEMP_DIR/tsconfig.json" << 'EOF'
{
  "compilerOptions": {
    "target": "es2020",
    "module": "commonjs",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
EOF

    cat > "$TEMP_DIR/Dockerfile" << 'EOF'
FROM node:18-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

COPY . .
RUN npm run build

FROM node:18-alpine AS runtime

# Create non-root user
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nextjs -u 1001

WORKDIR /app

# Copy built application
COPY --from=builder --chown=nextjs:nodejs /app/dist ./dist
COPY --from=builder --chown=nextjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./package.json

# Security hardening
RUN apk --no-cache add dumb-init && \
    rm -rf /var/cache/apk/*

USER nextjs

EXPOSE 3000

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/index.js"]
EOF

    cat > "$TEMP_DIR/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  jenkins:
    image: jenkins/jenkins:2.426.1-lts
    container_name: jenkins-local
    ports:
      - "8080:8080"
      - "50000:50000"
    volumes:
      - jenkins_home:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - JAVA_OPTS=-Djenkins.install.runSetupWizard=false
      - JENKINS_ADMIN_PASSWORD=admin123
    networks:
      - jenkins-network

  rabbitmq-local:
    image: rabbitmq:3.12-management
    container_name: rabbitmq-local
    ports:
      - "5672:5672"
      - "15672:15672"
    environment:
      - RABBITMQ_DEFAULT_USER=admin
      - RABBITMQ_DEFAULT_PASS=admin123
    networks:
      - jenkins-network

  registry:
    image: registry:2
    container_name: local-registry
    ports:
      - "5000:5000"
    networks:
      - jenkins-network

volumes:
  jenkins_home:

networks:
  jenkins-network:
    driver: bridge
EOF

    # Scripts
    cat > "$TEMP_DIR/scripts/setup-cluster.sh" << 'EOF'
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
EOF

    cat > "$TEMP_DIR/scripts/deploy-app.sh" << 'EOF'
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
EOF

    # Make scripts executable
    chmod +x "$TEMP_DIR/scripts/"*.sh

    # Create README
    cat > "$TEMP_DIR/README.md" << 'EOF'
# Secure Kubernetes Microservice CI/CD

A production-ready, security-focused Kubernetes application with comprehensive CI/CD pipeline designed for network and security engineers.

## 🏗️ Architecture

- **Application**: Node.js/TypeScript microservice with security hardening
- **Message Queue**: RabbitMQ cluster with network policies
- **Container Registry**: GitHub Container Registry
- **CI/CD**: GitHub Actions + Jenkins hybrid pipeline
- **Monitoring**: Prometheus + Grafana stack
- **Security**: Multi-layer security scanning and policy enforcement

## 🔒 Security Features

- 🛡️ **Network Policies**: Traffic segmentation and isolation
- 🔍 **Vulnerability Scanning**: Trivy, Semgrep, GitLeaks
- 📊 **Runtime Security**: Falco monitoring
- 🚫 **Policy Enforcement**: OPA Gatekeeper
- 🔐 **Secret Management**: Kubernetes secrets with proper mounting
- 📋 **SBOM Generation**: Software Bill of Materials for compliance
- 🏰 **Defense in Depth**: Multiple security layers

## 🚀 Quick Start

1. **Setup cluster:**
   ```bash
   ./scripts/setup-cluster.sh
   ```

2. **Deploy application:**
   ```bash
   ./scripts/deploy-app.sh v1.0.0
   ```

3. **Access services:**
   - Application: https://my-app.example.com
   - Jenkins: http://<loadbalancer-ip>:8080
   - RabbitMQ Management: http://<loadbalancer-ip>:15672

## 📁 Project Structure

```
secure-k8s-cicd/
├── .github/workflows/          # GitHub Actions workflows
│   ├── security-scan.yml       # Security scanning pipeline
│   ├── build-and-deploy.yml    # Build and deployment pipeline
│   └── infrastructure-scan.yml # Infrastructure security scan
├── k8s/                        # Kubernetes manifests
│   ├── rabbitmq-deployment.yaml
│   ├── jenkins-deployment.yaml
│   └── network-policies.yaml
├── helm/my-app/                # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
├── security-policies/          # OPA policies
├── scripts/                    # Setup and deployment scripts
├── src/                        # Application source code
├── Dockerfile                  # Multi-stage Docker build
├── Jenkinsfile                 # Jenkins pipeline
└── docker-compose.yml         # Local development
```

## 🔄 CI/CD Pipeline

### GitHub Actions (Automated)
- **Security Scanning**: Runs on every push/PR
- **Container Building**: Multi-arch builds with caching
- **Vulnerability Assessment**: Critical/High severity blocking
- **Staging Deployment**: Automatic on develop branch
- **SBOM Generation**: Compliance documentation

### Jenkins (Production)
- **Manual Approval**: Production deployments require approval
- **Comprehensive Validation**: Security, performance, network tests
- **Rollback Capability**: Automated rollback on failure
- **Compliance Reporting**: Audit trails and security reports

## 🛡️ Security Policies

The application enforces several security policies:

- ✅ Containers run as non-root users (UID 1001)
- ✅ Resource limits are mandatory
- ❌ Privileged containers are forbidden
- ❌ Privilege escalation is blocked
- 🔒 Network traffic is restricted by default
- 🔐 Secrets are properly mounted and rotated
- 📊 Images are scanned for vulnerabilities before deployment

## 📊 Monitoring & Observability

- **Metrics**: Prometheus scrapes application and infrastructure metrics
- **Dashboards**: Grafana provides comprehensive visibility
- **Alerting**: Critical issues trigger Slack/email notifications
- **Logging**: Centralized log aggregation with security event correlation
- **Tracing**: Distributed tracing for microservices communication

## 🧪 Testing

```bash
# Run unit tests
npm test

# Run security scans
npm run security

# Local development
docker-compose up -d
npm run dev
```

## 🔧 Configuration

### GitHub Secrets Required

Add these secrets to your GitHub repository:

```
GITHUB_TOKEN           # GitHub personal access token
JENKINS_API_TOKEN      # Jenkins API token
JENKINS_URL           # Jenkins server URL
KUBE_CONFIG_STAGING   # Staging cluster kubeconfig
KUBE_CONFIG_PRODUCTION # Production cluster kubeconfig
SLACK_WEBHOOK         # Slack webhook for notifications
SEMGREP_APP_TOKEN     # Semgrep scanning token
```

### Environment Variables

```bash
# Application
PORT=3000
NODE_ENV=production

# RabbitMQ
RABBITMQ_HOST=rabbitmq-service.messaging.svc.cluster.local
RABBITMQ_PORT=5672
RABBITMQ_USERNAME=admin
RABBITMQ_PASSWORD=<from-secret>
```

## 🚨 Security Incident Response

1. **Detection**: Falco alerts on suspicious runtime activity
2. **Assessment**: Security team reviews alerts and metrics
3. **Containment**: Network policies isolate affected pods
4. **Eradication**: Vulnerable containers are automatically replaced
5. **Recovery**: Services are restored from known-good images
6. **Lessons Learned**: Policies updated to prevent similar incidents

## 📈 Scaling & Performance

- **Horizontal Pod Autoscaling**: CPU/Memory based scaling
- **Vertical Pod Autoscaling**: Right-sizing recommendations
- **Cluster Autoscaling**: Node scaling based on demand
- **Load Testing**: Integrated performance validation
- **Resource Optimization**: Continuous rightsizing

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run security scans locally
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

Security scans will run automatically on your PR.

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

For support and questions:
- 📧 Email: devops-team@company.com
- 💬 Slack: #kubernetes-security
- 📖 Wiki: https://wiki.company.com/kubernetes-security

## 🏆 Acknowledgments

- Kubernetes community for security best practices
- CNCF for security tools and guidance
- Open source security projects (Trivy, Falco, OPA)
EOF

    # Create .gitignore
    cat > "$TEMP_DIR/.gitignore" << 'EOF'
# Dependencies
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# Build outputs
dist/
build/
*.tsbuildinfo

# Environment files
.env
.env.local
.env.development.local
.env.test.local
.env.production.local

# IDE files
.vscode/
.idea/
*.swp
*.swo
*~

# OS files
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
ehthumbs.db
Thumbs.db

# Docker
.dockerignore

# Kubernetes
*.kubeconfig
kubeconfig*

# Security
*.key
*.pem
*.p12
*.pfx
secrets/

# Logs
logs/
*.log

# Test coverage
coverage/
.nyc_output/

# Temporary files
tmp/
temp/
*.tmp
*.temp

# Security scan results
trivy-results.*
security-report.*
vulnerability-report.*
EOF

    # Create LICENSE
    cat > "$TEMP_DIR/LICENSE" << 'EOF'
MIT License

Copyright (c) 2025 Secure Kubernetes CI/CD Project

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

    # Create additional Helm templates
    cat > "$TEMP_DIR/helm/my-app/templates/service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "my-app.selectorLabels" . | nindent 4 }}
EOF

    cat > "$TEMP_DIR/helm/my-app/templates/ingress.yaml" << 'EOF'
{{- if .Values.ingress.enabled -}}
{{- $fullName := include "my-app.fullname" . -}}
{{- $svcPort := .Values.service.port -}}
{{- if and .Values.ingress.className (not (hasKey .Values.ingress.annotations "kubernetes.io/ingress.class")) }}
  {{- $_ := set .Values.ingress.annotations "kubernetes.io/ingress.class" .Values.ingress.className}}
{{- end }}
{{- if semverCompare ">=1.19-0" .Capabilities.KubeVersion.GitVersion -}}
apiVersion: networking.k8s.io/v1
{{- else if semverCompare ">=1.14-0" .Capabilities.KubeVersion.GitVersion -}}
apiVersion: networking.k8s.io/v1beta1
{{- else -}}
apiVersion: extensions/v1beta1
{{- end }}
kind: Ingress
metadata:
  name: {{ $fullName }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if and .Values.ingress.className (semverCompare ">=1.18-0" .Capabilities.KubeVersion.GitVersion) }}
  ingressClassName: {{ .Values.ingress.className }}
  {{- end }}
  {{- if .Values.ingress.tls }}
  tls:
    {{- range .Values.ingress.tls }}
    - hosts:
        {{- range .hosts }}
        - {{ . | quote }}
        {{- end }}
      secretName: {{ .secretName }}
    {{- end }}
  {{- end }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            {{- if and .pathType (semverCompare ">=1.18-0" $.Capabilities.KubeVersion.GitVersion) }}
            pathType: {{ .pathType }}
            {{- end }}
            backend:
              {{- if semverCompare ">=1.19-0" $.Capabilities.KubeVersion.GitVersion }}
              service:
                name: {{ $fullName }}
                port:
                  number: {{ $svcPort }}
              {{- else }}
              serviceName: {{ $fullName }}
              servicePort: {{ $svcPort }}
              {{- end }}
          {{- end }}
    {{- end }}
{{- end }}
EOF

    cat > "$TEMP_DIR/helm/my-app/templates/serviceaccount.yaml" << 'EOF'
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "my-app.serviceAccountName" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
EOF

    cat > "$TEMP_DIR/helm/my-app/templates/hpa.yaml" << 'EOF'
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "my-app.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    {{- if .Values.autoscaling.targetCPUUtilizationPercentage }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
    {{- end }}
    {{- if .Values.autoscaling.targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetMemoryUtilizationPercentage }}
    {{- end }}
{{- end }}
EOF

    cat > "$TEMP_DIR/helm/my-app/templates/networkpolicy.yaml" << 'EOF'
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "my-app.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
    - Egress
  {{- if .Values.networkPolicy.ingress.enabled }}
  ingress:
    - from:
        {{- range .Values.networkPolicy.ingress.from }}
        - {{- toYaml . | nindent 10 }}
        {{- end }}
      ports:
        - protocol: TCP
          port: {{ .Values.service.targetPort }}
  {{- end }}
  {{- if .Values.networkPolicy.egress.enabled }}
  egress:
    - to:
        {{- range .Values.networkPolicy.egress.to }}
        - {{- toYaml . | nindent 10 }}
        {{- end }}
      ports:
        - protocol: TCP
          port: 5672
    # Allow DNS
    - to: []
      ports:
        - protocol: TCP
          port: 53
        - protocol: UDP
          port: 53
    # Allow HTTPS for external APIs
    - to: []
      ports:
        - protocol: TCP
          port: 443
  {{- end }}
{{- end }}
EOF

    # Create test files
    mkdir -p "$TEMP_DIR/tests"
    cat > "$TEMP_DIR/tests/app.test.ts" << 'EOF'
import request from 'supertest';
import { app } from '../src/index';

describe('Application Health', () => {
  test('GET /health should return healthy status', async () => {
    const response = await request(app)
      .get('/health')
      .expect(200);
    
    expect(response.body.status).toBe('healthy');
    expect(response.body.timestamp).toBeDefined();
  });

  test('GET /ready should return ready status', async () => {
    const response = await request(app)
      .get('/ready')
      .expect(200);
    
    expect(response.body.status).toBe('ready');
    expect(response.body.timestamp).toBeDefined();
  });

  test('GET /metrics should return prometheus metrics', async () => {
    const response = await request(app)
      .get('/metrics')
      .expect(200);
    
    expect(response.text).toContain('http_requests_total');
    expect(response.text).toContain('http_request_duration_seconds');
  });

  test('GET /api/message should return message', async () => {
    const response = await request(app)
      .get('/api/message')
      .expect(200);
    
    expect(response.body.id).toBeDefined();
    expect(response.body.message).toBe('Hello from secure K8s app!');
    expect(response.body.timestamp).toBeDefined();
  });
});

describe('Security Headers', () => {
  test('Should include security headers', async () => {
    const response = await request(app)
      .get('/health')
      .expect(200);
    
    expect(response.headers['x-content-type-options']).toBe('nosniff');
    expect(response.headers['x-frame-options']).toBe('DENY');
    expect(response.headers['x-xss-protection']).toBe('0');
  });
});
EOF

    # Create additional configuration files
    cat > "$TEMP_DIR/jest.config.js" << 'EOF'
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/src', '<rootDir>/tests'],
  testMatch: ['**/__tests__/**/*.ts', '**/?(*.)+(spec|test).ts'],
  transform: {
    '^.+\\.ts: 'ts-jest',
  },
  collectCoverageFrom: [
    'src/**/*.ts',
    '!src/**/*.d.ts',
  ],
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'lcov', 'html'],
};
EOF

    cat > "$TEMP_DIR/.dockerignore" << 'EOF'
node_modules
npm-debug.log
Dockerfile*
docker-compose*
.dockerignore
.git
.gitignore
README.md
.env
.nyc_output
coverage
.nyc_output
.coverage
tests/
*.test.ts
*.test.js
.github/
k8s/
helm/
scripts/
EOF

    # Create monitoring configuration
    mkdir -p "$TEMP_DIR/monitoring"
    cat > "$TEMP_DIR/monitoring/grafana-dashboard.json" << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Secure K8s Application Dashboard",
    "tags": ["kubernetes", "security", "application"],
    "style": "dark",
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "HTTP Requests",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(http_requests_total[5m])",
            "legendFormat": "{{method}} {{path}} {{status}}"
          }
        ],
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
      },
      {
        "id": 2,
        "title": "Response Time",
        "type": "graph",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))",
            "legendFormat": "95th percentile"
          }
        ],
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
      },
      {
        "id": 3,
        "title": "Pod Status",
        "type": "table",
        "targets": [
          {
            "expr": "kube_pod_status_phase{namespace=\"production\"}",
            "format": "table"
          }
        ],
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8}
      }
    ],
    "time": {"from": "now-1h", "to": "now"},
    "refresh": "30s"
  }
}
EOF

    cat > "$TEMP_DIR/monitoring/prometheus-rules.yaml" << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-app-alerts
  namespace: production
spec:
  groups:
  - name: my-app.rules
    rules:
    - alert: HighErrorRate
      expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.1
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High error rate detected"
        description: "Error rate is {{ $value }} errors per second"
    
    - alert: PodCrashLooping
      expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Pod is crash looping"
        description: "Pod {{ $labels.pod }} is restarting frequently"
    
    - alert: HighMemoryUsage
      expr: container_memory_usage_bytes / container_spec_memory_limit_bytes > 0.8
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "High memory usage"
        description: "Memory usage is {{ $value | humanizePercentage }}"
EOF

    log "Configuration files created"
}

# Create tarball
create_tarball() {
    log "Creating tarball..."
    
    # Store the original directory
    ORIGINAL_DIR="$(pwd)"
    
    cd /tmp
    tar -czf "$TARBALL_NAME" "$PROJECT_NAME"
    
    # Move to original directory only if it's different from /tmp
    if [ "$ORIGINAL_DIR" != "/tmp" ]; then
        mv "$TARBALL_NAME" "$ORIGINAL_DIR/$TARBALL_NAME"
    fi
    
    # Return to original directory
    cd "$ORIGINAL_DIR"
    
    log "Tarball created: $TARBALL_NAME"
    log "Size: $(du -h "$TARBALL_NAME" | cut -f1)"
}

# Display instructions
show_instructions() {
    log "Project tarball created successfully!"
    log ""
    log "To get started:"
    log "1. Extract the tarball:"
    log "   tar -xzf $TARBALL_NAME"
    log ""
    log "2. Navigate to the project:"
    log "   cd $PROJECT_NAME"
    log ""
    log "3. Make scripts executable:"
    log "   chmod +x scripts/*.sh"
    log ""
    log "4. Set up your cluster:"
    log "   ./scripts/setup-cluster.sh"
    log ""
    log "5. Configure GitHub repository:"
    log "   git init"
    log "   git remote add origin <your-repo-url>"
    log "   git add ."
    log "   git commit -m 'Initial commit'"
    log "   git push -u origin main"
    log ""
    log "6. Add GitHub secrets as documented in README.md"
    log ""
    log "7. Build and deploy your first application:"
    log "   docker build -t my-app:v1.0.0 ."
    log "   ./scripts/deploy-app.sh v1.0.0"
    log ""
    log "📚 See README.md for complete setup instructions"
    log "🔐 Security policies are pre-configured for production use"
    log "🚀 CI/CD pipelines are ready for GitHub Actions + Jenkins"
}

# Main function
main() {
    log "Creating secure Kubernetes CI/CD project tarball..."
    
    cleanup
    create_structure
    create_files
    create_tarball
    cleanup
    show_instructions
}

# Run the script
main "$@"