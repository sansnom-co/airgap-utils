# K0rdent Airgap Addon Bundles

Addon bundles for K0rdent airgap environments. These bundles include both container images and Helm charts/manifests in a format compatible with the standard K0rdent bundle loading process.

## 📦 Bundle Structure

Each bundle archive (`*-addon-bundle.tar.gz`) includes:

```

addon-bundle/
├── images/      # OCI image tars (*.tar)
├── charts/      # Helm charts as OCI tars (*.tar)
└── manifests/   # Raw YAMLs for non-Helm addons (\*.yaml)

````

## ⚙️ Build Script

Use the provided script to build addon bundles:

```bash
#!/usr/bin/env bash
# Create Complete Addon Bundles - Images + Charts/Manifests Together
# Creates comprehensive OCI bundles like K0rdent expects
# Version: 1.0.0
````

## 📥 Installation

1. **Extract the bundle**:

   ```bash
   tar -xzf velero-addon-bundle.tar.gz
   ```

2. **(Optional)** Merge with a base K0rdent bundle:

   ```bash
   cp -r velero-addon-bundle/* /path/to/k0rdent-bundle/
   ```

3. **Load via standard K0rdent script**:

   ```bash
   ./scripts/main/06-load-images-and-charts.sh
   ```

## 📚 Available Bundles

### 🔹 Velero Backup Solution

* **Bundle**: `velero-addon-bundle.tar.gz`
* **Contains**:

  * 7 images + Helm chart
  * Velero core + plugins (AWS, GCP, Azure, CSI)
  * Restore helper + kubectl

### 🔹 Local Path Provisioner

* **Bundle**: `local-path-addon-bundle.tar.gz`
* **Contains**:

  * 2 images + raw manifest
* **Deploy**: `kubectl apply -f`

### 🔹 OpenEBS Storage

* **Bundle**: `openebs-addon-bundle.tar.gz`
* **Contains**:

  * 4 images + Helm chart
* **Deploy**: `helm install` after loading

## 📝 Notes

* Bundles follow **K0rdent's airgap format** exactly
* Images and charts are co-located for streamlined loading
* **Registry rewriting** is handled automatically by the loader
* Raw manifests may need manual registry URL updates

This approach ensures full compatibility with existing K0rdent airgap workflows — no changes needed.

```
## martin / mes
