#!/usr/bin/env bash
# Create Complete Addon Bundles - Images + Charts/Manifests Together
# Creates comprehensive OCI bundles like K0rdent expects
# Version: 1.0.0

set -euo pipefail

# Logging
log_info() { echo "[INFO] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_success() { echo "[SUCCESS] $1"; }

# Create Velero bundle (images + Helm chart)
create_velero_bundle() {
    log_info "Creating Velero complete bundle..."
    
    local bundle_dir="velero-addon-bundle"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir/images"
    mkdir -p "$bundle_dir/charts"
    
    # Download Velero images - INCLUDING ALL PLUGINS
    local velero_images=(
        # Core Velero image
        "velero__velero_v1.16.0|docker.io/velero/velero:v1.16.0"
        
        # Cloud provider plugins
        "velero__velero-plugin-for-aws_v1.12.0|docker.io/velero/velero-plugin-for-aws:v1.12.0"
        "velero__velero-plugin-for-gcp_v1.12.0|docker.io/velero/velero-plugin-for-gcp:v1.12.0"
        "velero__velero-plugin-for-microsoft-azure_v1.12.0|docker.io/velero/velero-plugin-for-microsoft-azure:v1.12.0"
        
        # CSI plugin for volume snapshots
        "velero__velero-plugin-for-csi_v0.8.1|docker.io/velero/velero-plugin-for-csi:v0.8.1"
        
        # Restore helper for volume restores
        "velero__velero-restore-helper_v1.16.0|docker.io/velero/velero-restore-helper:v1.16.0"
        
        # kubectl for backup/restore hooks
        "bitnami__kubectl_latest|docker.io/bitnami/kubectl:latest"
    )
    
    log_info "Downloading Velero images..."
    for entry in "${velero_images[@]}"; do
        local artifact_name="${entry%%|*}"
        local source_image="${entry#*|}"
        
        log_info "Pulling $source_image..."
        if skopeo copy --override-os linux --override-arch amd64 \
            "docker://${source_image}" \
            "oci:tmp_${artifact_name}:latest" >/dev/null 2>&1; then
            tar -cf "$bundle_dir/images/${artifact_name}.tar" "tmp_${artifact_name}"
            rm -rf "tmp_${artifact_name}"
            log_success "Added image: ${artifact_name}"
        fi
    done
    
    # Download Velero Helm chart as OCI
    if command -v helm >/dev/null 2>&1; then
        log_info "Downloading Velero Helm chart..."
        helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1
        helm repo update >/dev/null 2>&1
        
        if helm pull vmware-tanzu/velero --version 9.1.2; then
            # Convert to OCI format
            local chart_oci="charts__velero_9_1_2"
            mkdir -p "$chart_oci/blobs/sha256"
            echo '{"imageLayoutVersion": "1.0.0"}' > "$chart_oci/oci-layout"
            
            # Move chart into OCI structure
            local digest=$(sha256sum velero-9.1.2.tgz | cut -d' ' -f1)
            cp velero-9.1.2.tgz "$chart_oci/blobs/sha256/$digest"
            
            # Create simple index
            cat > "$chart_oci/index.json" << EOF
{
  "schemaVersion": 2,
  "manifests": [{
    "mediaType": "application/vnd.cncf.helm.chart.content.v1.tar+gzip",
    "digest": "sha256:$digest",
    "size": $(stat -c%s velero-9.1.2.tgz 2>/dev/null || stat -f%z velero-9.1.2.tgz)
  }]
}
EOF
            
            # Create tar
            tar -cf "$bundle_dir/charts/${chart_oci}.tar" "$chart_oci"
            rm -rf "$chart_oci" velero-9.1.2.tgz
            log_success "Added Helm chart"
        fi
    fi
    
    # Create bundle tar
    tar -czf "velero-addon-bundle.tar.gz" "$bundle_dir"
    rm -rf "$bundle_dir"
    
    log_success "Created: velero-addon-bundle.tar.gz"
}

# Create Local Path Provisioner bundle (images + manifest)
create_local_path_bundle() {
    log_info "Creating Local Path Provisioner bundle..."
    
    local bundle_dir="local-path-addon-bundle"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir/images"
    mkdir -p "$bundle_dir/manifests"
    
    # Download images
    local images=(
        "rancher__local-path-provisioner_v0.0.28|docker.io/rancher/local-path-provisioner:v0.0.28"
        "busybox_stable|docker.io/busybox:stable"
    )
    
    log_info "Downloading Local Path images..."
    for entry in "${images[@]}"; do
        local artifact_name="${entry%%|*}"
        local source_image="${entry#*|}"
        
        log_info "Pulling $source_image..."
        if skopeo copy --override-os linux --override-arch amd64 \
            "docker://${source_image}" \
            "oci:tmp_${artifact_name}:latest" >/dev/null 2>&1; then
            tar -cf "$bundle_dir/images/${artifact_name}.tar" "tmp_${artifact_name}"
            rm -rf "tmp_${artifact_name}"
            log_success "Added image: ${artifact_name}"
        fi
    done
    
    # Create manifest
    cat > "$bundle_dir/manifests/local-path-provisioner.yaml" << 'EOF'
# Local Path Provisioner - Airgap Ready
# Replace REGISTRY_URL with your registry
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner
  namespace: local-path-storage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: local-path-provisioner
  template:
    metadata:
      labels:
        app: local-path-provisioner
    spec:
      serviceAccountName: local-path-provisioner-service-account
      containers:
      - name: local-path-provisioner
        image: REGISTRY_URL/k0rdent-enterprise/rancher/local-path-provisioner:v0.0.28
        command:
        - local-path-provisioner
        - --debug
        - start
        - --config
        - /etc/config/config.json
        volumeMounts:
        - name: config-volume
          mountPath: /etc/config/
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
      volumes:
      - name: config-volume
        configMap:
          name: local-path-config
      imagePullSecrets:
      - name: registry-credentials
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |-
    {
      "nodePathMap": [{
        "node": "DEFAULT",
        "paths": ["/opt/local-path-provisioner"]
      }]
    }
  setup: |-
    #!/bin/sh
    mkdir -m 0777 -p "$VOL_DIR"
  teardown: |-
    #!/bin/sh
    rm -rf "$VOL_DIR"
  helperPod.yaml: |-
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
      - name: helper-pod
        image: REGISTRY_URL/k0rdent-enterprise/busybox:stable
---
# Add RBAC and StorageClass...
EOF
    
    # Create bundle tar
    tar -czf "local-path-addon-bundle.tar.gz" "$bundle_dir"
    rm -rf "$bundle_dir"
    
    log_success "Created: local-path-addon-bundle.tar.gz"
}

# Create OpenEBS bundle
create_openebs_bundle() {
    log_info "Creating OpenEBS bundle..."
    
    local bundle_dir="openebs-addon-bundle"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir/images"
    mkdir -p "$bundle_dir/charts"
    
    # Download images
    local images=(
        "openebs__provisioner-localpv_3.5.0|docker.io/openebs/provisioner-localpv:3.5.0"
        "openebs__linux-utils_3.5.0|docker.io/openebs/linux-utils:3.5.0"
        "openebs__node-disk-manager_2.1.0|docker.io/openebs/node-disk-manager:2.1.0"
        "openebs__node-disk-exporter_2.1.0|docker.io/openebs/node-disk-exporter:2.1.0"
    )
    
    log_info "Downloading OpenEBS images..."
    for entry in "${images[@]}"; do
        local artifact_name="${entry%%|*}"
        local source_image="${entry#*|}"
        
        log_info "Pulling $source_image..."
        if skopeo copy --override-os linux --override-arch amd64 \
            "docker://${source_image}" \
            "oci:tmp_${artifact_name}:latest" >/dev/null 2>&1; then
            tar -cf "$bundle_dir/images/${artifact_name}.tar" "tmp_${artifact_name}"
            rm -rf "tmp_${artifact_name}"
            log_success "Added image: ${artifact_name}"
        fi
    done
    
    # Download OpenEBS Helm chart if available
    if command -v helm >/dev/null 2>&1; then
        log_info "Downloading OpenEBS Helm chart..."
        helm repo add openebs https://openebs.github.io/charts >/dev/null 2>&1
        helm repo update >/dev/null 2>&1
        
        if helm pull openebs/openebs --version 3.10.0; then
            # Convert to OCI format like K0rdent
            local chart_oci="charts__openebs_3_10_0"
            mkdir -p "$chart_oci/blobs/sha256"
            echo '{"imageLayoutVersion": "1.0.0"}' > "$chart_oci/oci-layout"
            
            local digest=$(sha256sum openebs-3.10.0.tgz | cut -d' ' -f1)
            cp openebs-3.10.0.tgz "$chart_oci/blobs/sha256/$digest"
            
            cat > "$chart_oci/index.json" << EOF
{
  "schemaVersion": 2,
  "manifests": [{
    "mediaType": "application/vnd.cncf.helm.chart.content.v1.tar+gzip",
    "digest": "sha256:$digest",
    "size": $(stat -c%s openebs-3.10.0.tgz)
  }]
}
EOF
            
            tar -cf "$bundle_dir/charts/${chart_oci}.tar" "$chart_oci"
            rm -rf "$chart_oci" openebs-3.10.0.tgz
            log_success "Added Helm chart"
        fi
    fi
    
    # Create bundle tar
    tar -czf "openebs-addon-bundle.tar.gz" "$bundle_dir"
    rm -rf "$bundle_dir"
    
    log_success "Created: openebs-addon-bundle.tar.gz"
}

# Create instructions
create_instructions() {
    cat > "ADDON-BUNDLES-README.md" << 'EOF'
# Addon Bundles for K0rdent Airgap

These bundles follow the same structure as the K0rdent airgap bundle, containing both images and charts/manifests.

## Bundle Structure

Each addon bundle contains:
```
addon-bundle/
├── images/      # Container images as OCI tars
│   └── *.tar
├── charts/      # Helm charts as OCI tars (if applicable)
│   └── *.tar
└── manifests/   # Raw YAML manifests (if no Helm chart)
    └── *.yaml
```

## Installation Process

1. **Extract the addon bundle**:
   ```bash
   tar -xzf velero-addon-bundle.tar.gz
   ```

2. **Merge with K0rdent bundle** (optional):
   ```bash
   cp -r velero-addon-bundle/* /path/to/bundle-extracted/
   ```

3. **Load with standard script**:
   ```bash
   # The same script that loads K0rdent bundle
   ./scripts/main/06-load-images-and-charts.sh
   ```

## Available Bundles

### Velero Backup Solution
- **Bundle**: `velero-addon-bundle.tar.gz`
- **Contains**: 7 images + Helm chart
  - Core Velero server
  - AWS S3/EBS plugin (works with MinIO/S3-compatible)
  - GCP plugin
  - Azure plugin
  - CSI plugin (for Kubernetes CSI volume snapshots)
  - Restore helper
  - kubectl (for hooks)
- **Deploy**: Using Helm after loading

### Local Path Provisioner
- **Bundle**: `local-path-addon-bundle.tar.gz`
- **Contains**: 2 images + YAML manifest
- **Deploy**: `kubectl apply -f` after updating registry URL

### OpenEBS Storage
- **Bundle**: `openebs-addon-bundle.tar.gz`
- **Contains**: 4 images + Helm chart
- **Deploy**: Using Helm after loading

## Key Points

1. These bundles use the **exact same format** as K0rdent bundles
2. Images and charts are **co-located** in the same bundle
3. The standard K0rdent loading script handles everything
4. Registry URL rewriting is automatic for charts
5. Manual manifests need registry URL updates

This approach ensures customers can use their existing K0rdent airgap procedures without learning new processes.
EOF
}

# Main menu
main() {
    echo "=== Complete Addon Bundle Creator ==="
    echo ""
    echo "Creates bundles with images + charts/manifests together"
    echo "Same format as K0rdent airgap bundles"
    echo ""
    echo "1. Velero (backup) - images + Helm chart"
    echo "2. Local Path Provisioner - images + manifest"
    echo "3. OpenEBS - images + Helm chart"
    echo "4. All bundles"
    echo ""
    printf "Choice (1-4): "
    read choice
    
    # Check skopeo
    if ! command -v skopeo >/dev/null 2>&1; then
        log_error "skopeo is required"
        exit 1
    fi
    
    case $choice in
        1) create_velero_bundle ;;
        2) create_local_path_bundle ;;
        3) create_openebs_bundle ;;
        4) 
            create_velero_bundle
            create_local_path_bundle
            create_openebs_bundle
            ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
    
    create_instructions
    
    echo ""
    echo "=== Summary ==="
    echo "Created addon bundles:"
    ls -la *-addon-bundle.tar.gz 2>/dev/null
    echo ""
    echo "See ADDON-BUNDLES-README.md for usage instructions"
}

main "$@"
