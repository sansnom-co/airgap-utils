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
