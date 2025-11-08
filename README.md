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
