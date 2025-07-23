#!/usr/bin/env bash
# Create Complete Addon Bundles with CalVer Naming - Robust Version
# Creates comprehensive OCI bundles like K0rdent expects
# Uses CalVer format: YYYY.MM.PATCH (e.g., 2025.01.0)
# No symlinks, no early exits

# Don't use set -e to avoid early exits
set -uo pipefail

# CalVer configuration
YEAR=$(date +%Y)
MONTH=$(date +%m)
PATCH="0"  # Increment for multiple releases in same month

# Allow override via environment
BUNDLE_VERSION="${BUNDLE_VERSION:-${YEAR}.${MONTH}.${PATCH}}"

# Logging
log_info() { echo "[INFO] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_success() { echo "[SUCCESS] $1"; }
log_warn() { echo "[WARN] $1"; }

# Create Velero bundle (images + Helm chart)
create_velero_bundle() {
    log_info "Creating Velero bundle v${BUNDLE_VERSION}..."
    
    local bundle_dir="velero-addon-bundle"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir/images"
    mkdir -p "$bundle_dir/charts"
    
    # Create version metadata
    cat > "$bundle_dir/VERSION" << EOF
bundle_version: ${BUNDLE_VERSION}
bundle_type: velero-addon
created_date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
component_versions:
  velero: v1.16.1
  helm_chart: 10.0.10
  plugin_aws: v1.12.1
  plugin_gcp: v1.12.1
  plugin_azure: v1.12.1
  plugin_csi: v0.7.1
  restore_helper: v1.15.2
EOF
    
    # Download Velero images - LATEST VERSIONS
    local velero_images=(
        # Core Velero image (latest: v1.16.1)
        "velero__velero_v1.16.1|docker.io/velero/velero:v1.16.1"
        
        # Cloud provider plugins (latest: v1.12.1)
        "velero__velero-plugin-for-aws_v1.12.1|docker.io/velero/velero-plugin-for-aws:v1.12.1"
        "velero__velero-plugin-for-gcp_v1.12.1|docker.io/velero/velero-plugin-for-gcp:v1.12.1"
        "velero__velero-plugin-for-microsoft-azure_v1.12.1|docker.io/velero/velero-plugin-for-microsoft-azure:v1.12.1"
        
        # CSI plugin for volume snapshots (latest: v0.7.1)
        "velero__velero-plugin-for-csi_v0.7.1|docker.io/velero/velero-plugin-for-csi:v0.7.1"
        
        # Restore helper for volume restores (latest: v1.15.2)
        "velero__velero-restore-helper_v1.15.2|docker.io/velero/velero-restore-helper:v1.15.2"
        
        # kubectl for backup/restore hooks
        "bitnami__kubectl_latest|docker.io/bitnami/kubectl:latest"
    )
    
    log_info "Downloading Velero images (7 total)..."
    local failed_images=()
    local success_count=0
    local total_images=${#velero_images[@]}
    
    for i in "${!velero_images[@]}"; do
        local entry="${velero_images[$i]}"
        local artifact_name="${entry%%|*}"
        local source_image="${entry#*|}"
        
        log_info "[$((i + 1))/${total_images}] Pulling $source_image..."
        
        # Create temp directory for this specific image
        local temp_dir="tmp_${artifact_name}"
        rm -rf "$temp_dir"
        
        # Try to pull the image
        if skopeo copy --override-os linux --override-arch amd64 \
            "docker://${source_image}" \
            "oci:${temp_dir}:latest" 2>&1; then
            
            # Create tar from the OCI directory
            if tar -cf "$bundle_dir/images/${artifact_name}.tar" "$temp_dir" 2>&1; then
                rm -rf "$temp_dir"
                log_success "Added image: ${artifact_name}"
                ((success_count++))
            else
                log_error "Failed to create tar for ${artifact_name}"
                rm -rf "$temp_dir"
                failed_images+=("$source_image")
            fi
        else
            log_error "Failed to pull $source_image"
            rm -rf "$temp_dir"
            failed_images+=("$source_image")
        fi
        
        # Continue to next image regardless of success/failure
    done
    
    log_info "Downloaded $success_count/${total_images} images successfully"
    
    if [[ ${#failed_images[@]} -gt 0 ]]; then
        log_error "Failed to download the following images:"
        for img in "${failed_images[@]}"; do
            echo "  - $img"
        done
    fi
    
    # Download Velero Helm chart as OCI (LATEST: 10.0.10)
    if command -v helm >/dev/null 2>&1; then
        log_info "Downloading Velero Helm chart v10.0.10 (latest)..."
        
        # Ensure helm repo is added
        helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts 2>&1 || true
        helm repo update 2>&1 || true
        
        if helm pull vmware-tanzu/velero --version 10.0.10 2>&1; then
            # Convert to OCI format
            local chart_oci="charts__velero_10_0_10"
            mkdir -p "$chart_oci/blobs/sha256"
            echo '{"imageLayoutVersion": "1.0.0"}' > "$chart_oci/oci-layout"
            
            # Move chart into OCI structure
            if [[ -f "velero-10.0.10.tgz" ]]; then
                local digest=$(sha256sum velero-10.0.10.tgz | cut -d' ' -f1)
                cp velero-10.0.10.tgz "$chart_oci/blobs/sha256/$digest"
                
                # Create simple index
                cat > "$chart_oci/index.json" << EOF
{
  "schemaVersion": 2,
  "manifests": [{
    "mediaType": "application/vnd.cncf.helm.chart.content.v1.tar+gzip",
    "digest": "sha256:$digest",
    "size": $(stat -c%s velero-10.0.10.tgz 2>/dev/null || stat -f%z velero-10.0.10.tgz || echo 0)
  }]
}
EOF
                
                # Create tar
                if tar -cf "$bundle_dir/charts/${chart_oci}.tar" "$chart_oci" 2>&1; then
                    rm -rf "$chart_oci" velero-10.0.10.tgz
                    log_success "Added Helm chart v10.0.10"
                else
                    log_error "Failed to create chart tar"
                fi
            else
                log_error "Helm chart file not found after pull"
            fi
        else
            log_error "Failed to download Helm chart"
        fi
    else
        log_warn "Helm not found, skipping chart download"
    fi
    
    # Create bundle tar with CalVer naming
    local bundle_name="velero-addon-bundle-${BUNDLE_VERSION}.tar.gz"
    
    log_info "Creating final bundle: $bundle_name"
    if tar -czf "$bundle_name" "$bundle_dir" 2>&1; then
        rm -rf "$bundle_dir"
        log_success "Created: $bundle_name"
        
        # Also create a -latest version (not symlink)
        cp "$bundle_name" "velero-addon-bundle-latest.tar.gz"
        log_info "Also created: velero-addon-bundle-latest.tar.gz"
    else
        log_error "Failed to create bundle tar"
        # Don't remove bundle_dir so user can see what was downloaded
    fi
}

# Create Local Path Provisioner bundle (images + manifest)
create_local_path_bundle() {
    log_info "Creating Local Path Provisioner bundle v${BUNDLE_VERSION}..."
    
    local bundle_dir="local-path-addon-bundle"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir/images"
    mkdir -p "$bundle_dir/manifests"
    
    # Create version metadata
    cat > "$bundle_dir/VERSION" << EOF
bundle_version: ${BUNDLE_VERSION}
bundle_type: local-path-addon
created_date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
component_versions:
  local_path_provisioner: v0.0.28
  busybox: stable
EOF
    
    # Download images
    local images=(
        "rancher__local-path-provisioner_v0.0.28|docker.io/rancher/local-path-provisioner:v0.0.28"
        "busybox_stable|docker.io/busybox:stable"
    )
    
    log_info "Downloading Local Path images..."
    local success_count=0
    local total_images=${#images[@]}
    
    for i in "${!images[@]}"; do
        local entry="${images[$i]}"
        local artifact_name="${entry%%|*}"
        local source_image="${entry#*|}"
        
        log_info "[$((i + 1))/${total_images}] Pulling $source_image..."
        
        local temp_dir="tmp_${artifact_name}"
        rm -rf "$temp_dir"
        
        if skopeo copy --override-os linux --override-arch amd64 \
            "docker://${source_image}" \
            "oci:${temp_dir}:latest" 2>&1; then
            
            if tar -cf "$bundle_dir/images/${artifact_name}.tar" "$temp_dir" 2>&1; then
                rm -rf "$temp_dir"
                log_success "Added image: ${artifact_name}"
                ((success_count++))
            else
                log_error "Failed to create tar for ${artifact_name}"
                rm -rf "$temp_dir"
            fi
        else
            log_error "Failed to pull $source_image"
            rm -rf "$temp_dir"
        fi
    done
    
    log_info "Downloaded $success_count/${total_images} images"
    
    # Create complete manifest with RBAC and StorageClass
    cat > "$bundle_dir/manifests/local-path-provisioner.yaml" << 'EOF'
# Local Path Provisioner - Airgap Ready
# Replace REGISTRY_URL with your registry
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-path-provisioner-service-account
  namespace: local-path-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
  - apiGroups: [""]
    resources: ["nodes", "persistentvolumeclaims", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["endpoints", "persistentvolumes", "pods"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: local-path-storage
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
      imagePullSecrets:
      - name: registry-credentials
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
    
    # Create bundle tar with CalVer naming
    local bundle_name="local-path-addon-bundle-${BUNDLE_VERSION}.tar.gz"
    
    log_info "Creating final bundle: $bundle_name"
    if tar -czf "$bundle_name" "$bundle_dir" 2>&1; then
        rm -rf "$bundle_dir"
        log_success "Created: $bundle_name"
        
        # Also create a -latest version (not symlink)
        cp "$bundle_name" "local-path-addon-bundle-latest.tar.gz"
        log_info "Also created: local-path-addon-bundle-latest.tar.gz"
    else
        log_error "Failed to create bundle tar"
    fi
}

# Create OpenEBS bundle
create_openebs_bundle() {
    log_info "Creating OpenEBS bundle v${BUNDLE_VERSION}..."
    
    local bundle_dir="openebs-addon-bundle"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir/images"
    mkdir -p "$bundle_dir/charts"
    
    # Create version metadata
    cat > "$bundle_dir/VERSION" << EOF
bundle_version: ${BUNDLE_VERSION}
bundle_type: openebs-addon
created_date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
component_versions:
  openebs_chart: 3.10.0
  provisioner_localpv: 3.5.0
  linux_utils: 3.5.0
  node_disk_manager: 2.1.0
  node_disk_exporter: 2.1.0
EOF
    
    # Download images
    local images=(
        "openebs__provisioner-localpv_3.5.0|docker.io/openebs/provisioner-localpv:3.5.0"
        "openebs__linux-utils_3.5.0|docker.io/openebs/linux-utils:3.5.0"
        "openebs__node-disk-manager_2.1.0|docker.io/openebs/node-disk-manager:2.1.0"
        "openebs__node-disk-exporter_2.1.0|docker.io/openebs/node-disk-exporter:2.1.0"
    )
    
    log_info "Downloading OpenEBS images..."
    local success_count=0
    local total_images=${#images[@]}
    
    for i in "${!images[@]}"; do
        local entry="${images[$i]}"
        local artifact_name="${entry%%|*}"
        local source_image="${entry#*|}"
        
        log_info "[$((i + 1))/${total_images}] Pulling $source_image..."
        
        local temp_dir="tmp_${artifact_name}"
        rm -rf "$temp_dir"
        
        if skopeo copy --override-os linux --override-arch amd64 \
            "docker://${source_image}" \
            "oci:${temp_dir}:latest" 2>&1; then
            
            if tar -cf "$bundle_dir/images/${artifact_name}.tar" "$temp_dir" 2>&1; then
                rm -rf "$temp_dir"
                log_success "Added image: ${artifact_name}"
                ((success_count++))
            else
                log_error "Failed to create tar for ${artifact_name}"
                rm -rf "$temp_dir"
            fi
        else
            log_error "Failed to pull $source_image"
            rm -rf "$temp_dir"
        fi
    done
    
    log_info "Downloaded $success_count/${total_images} images"
    
    # Download OpenEBS Helm chart if available
    if command -v helm >/dev/null 2>&1; then
        log_info "Downloading OpenEBS Helm chart..."
        
        helm repo add openebs https://openebs.github.io/charts 2>&1 || true
        helm repo update 2>&1 || true
        
        if helm pull openebs/openebs --version 3.10.0 2>&1; then
            # Convert to OCI format like K0rdent
            local chart_oci="charts__openebs_3_10_0"
            mkdir -p "$chart_oci/blobs/sha256"
            echo '{"imageLayoutVersion": "1.0.0"}' > "$chart_oci/oci-layout"
            
            if [[ -f "openebs-3.10.0.tgz" ]]; then
                local digest=$(sha256sum openebs-3.10.0.tgz | cut -d' ' -f1)
                cp openebs-3.10.0.tgz "$chart_oci/blobs/sha256/$digest"
                
                cat > "$chart_oci/index.json" << EOF
{
  "schemaVersion": 2,
  "manifests": [{
    "mediaType": "application/vnd.cncf.helm.chart.content.v1.tar+gzip",
    "digest": "sha256:$digest",
    "size": $(stat -c%s openebs-3.10.0.tgz 2>/dev/null || stat -f%z openebs-3.10.0.tgz || echo 0)
  }]
}
EOF
                
                if tar -cf "$bundle_dir/charts/${chart_oci}.tar" "$chart_oci" 2>&1; then
                    rm -rf "$chart_oci" openebs-3.10.0.tgz
                    log_success "Added Helm chart"
                else
                    log_error "Failed to create chart tar"
                fi
            else
                log_error "Chart file not found after pull"
            fi
        else
            log_error "Failed to download Helm chart"
        fi
    fi
    
    # Create bundle tar with CalVer naming
    local bundle_name="openebs-addon-bundle-${BUNDLE_VERSION}.tar.gz"
    
    log_info "Creating final bundle: $bundle_name"
    if tar -czf "$bundle_name" "$bundle_dir" 2>&1; then
        rm -rf "$bundle_dir"
        log_success "Created: $bundle_name"
        
        # Also create a -latest version (not symlink)
        cp "$bundle_name" "openebs-addon-bundle-latest.tar.gz"
        log_info "Also created: openebs-addon-bundle-latest.tar.gz"
    else
        log_error "Failed to create bundle tar"
    fi
}

# Main menu
main() {
    echo "=== Addon Bundle Creator - Robust Version ==="
    echo ""
    echo "Bundle Version: ${BUNDLE_VERSION}"
    echo "Format: YYYY.MM.PATCH (e.g., 2025.01.0)"
    echo ""
    echo "Options:"
    echo "1. Velero (backup) - images + Helm chart"
    echo "2. Local Path Provisioner - images + manifest"
    echo "3. OpenEBS - images + Helm chart"
    echo "4. All bundles"
    echo ""
    printf "Choice (1-4): "
    read choice
    
    # Check skopeo
    if ! command -v skopeo >/dev/null 2>&1; then
        log_error "skopeo is required for creating bundles"
        exit 1
    fi
    
    case $choice in
        1) create_velero_bundle ;;
        2) create_local_path_bundle ;;
        3) create_openebs_bundle ;;
        4) 
            create_velero_bundle
            echo ""
            create_local_path_bundle
            echo ""
            create_openebs_bundle
            ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
    
    echo ""
    echo "=== Summary ==="
    echo "Bundle operations completed. Check for any errors above."
    echo ""
    echo "Created bundles:"
    ls -la *-addon-bundle-${BUNDLE_VERSION}.tar.gz 2>/dev/null || echo "No versioned bundles found"
    echo ""
    echo "Latest versions:"
    ls -la *-addon-bundle-latest.tar.gz 2>/dev/null || echo "No latest bundles found"
    echo ""
    echo "Incomplete bundles (if any):"
    ls -ld *-addon-bundle 2>/dev/null || echo "No incomplete bundles found"
}

# Run main function
main "$@"
