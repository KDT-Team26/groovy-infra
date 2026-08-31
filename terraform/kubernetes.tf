# Kubernetes application resources are intentionally not managed by Terraform.
#
# Management boundary:
# - Terraform manages AWS infrastructure.
# - Argo CD and Helm manage Kubernetes application resources.
#
# Namespace, ServiceAccount, ConfigMap, Deployment, Service,
# Ingress, and Helm Release are managed through GitOps.