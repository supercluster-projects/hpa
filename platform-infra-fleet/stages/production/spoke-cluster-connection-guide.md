# Connecting Spoke Clusters to central Hub Argo CD (M1 Task M1.3.3)

This guide documents the declarative and CLI-based process of connecting on-premises or virtualized remote spoke clusters into the central Hub Management Plane using Kubernetes Service Account Tokens.

## Steps

### Step 1: Create Service Account on the Spoke Cluster
On the target Spoke cluster (e.g., `spoke-prod-1`), apply the following manifest to define the permissions Argo CD needs:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: argocd-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: argocd-system
```

### Step 2: Extract the Service Account Bearer Token
Run the following commands on the Spoke cluster to retrieve the target cluster endpoint and SA bearer token:

```bash
# Get the Spoke API Endpoint
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Extract Token
SECRET_NAME=$(kubectl -n argocd-system get serviceaccount argocd-manager -o jsonpath='{.secrets[0].name}')
TOKEN=$(kubectl -n argocd-system get secret ${SECRET_NAME} -o jsonpath='{.data.token}' | base64 -d)
```

### Step 3: Register the Spoke Cluster on the Hub Management Plane
Define a Kubernetes Secret manifest on the central Hub Cluster to register the spoke. Argo CD dynamically watches for secrets with the label `argocd.argoproj.io/secret-type: cluster`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: spoke-prod-1-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: spoke-prod-1
  server: "https://<spoke-api-server-ip>:6443"
  config: |
    {
      "bearerToken": "<extracted-bearer-token>",
      "tlsClientConfig": {
        "insecure": true
      }
    }
```

Apply this secret to the Hub Cluster:
`kubectl apply -f spoke-prod-1-secret.yaml`

Argo CD will automatically discover the Spoke and allow ApplicationSet resources to deploy services targeting it.
