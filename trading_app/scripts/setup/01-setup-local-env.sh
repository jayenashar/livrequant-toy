#!/bin/bash

# 01-setup-local-env.sh
FORCE_RECREATE=false

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --force-recreate) FORCE_RECREATE=true ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

echo "Starting local Kubernetes environment setup..."

# Check if script is being run as root
if [ "$(id -u)" -eq 0 ]; then
    echo "Error: This script should not be run as root or with sudo"
    echo "The KVM driver creates a full virtual machine rather than running inside a container."
    echo "Please run the script as a regular user"
    exit 1
fi

# Check if curl is installed, install if missing
if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found. Installing..."
    sudo apt-get update && sudo apt-get install -y curl
fi

# Check if Docker is installed, install if missing
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"
    echo "Docker installed. Please log out and log back in for group changes to take effect if this is your first install."
fi

# Check if minikube is installed, install if missing
if ! command -v minikube >/dev/null 2>&1; then
    echo "Minikube not found. Installing..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        MINIKUBE_ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        MINIKUBE_ARCH="arm64"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi
    echo "Detected architecture: $ARCH ($MINIKUBE_ARCH)"
    curl -Lo minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-$MINIKUBE_ARCH"
    chmod +x minikube
    sudo mv minikube /usr/local/bin/
fi

# Check if kubectl is installed, install if missing
if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not found. Installing..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        KUBECTL_ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        KUBECTL_ARCH="arm64"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi
    echo "Detected architecture: $ARCH ($KUBECTL_ARCH)"
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/$KUBECTL_ARCH/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
fi

# Check if Minikube is running, if not start it
minikube status >/dev/null 2>&1
MINIKUBE_STATUS=$?

if [ $MINIKUBE_STATUS -ne 0 ] || [ "$FORCE_RECREATE" = true ]; then
    if [ "$FORCE_RECREATE" = true ] && [ $MINIKUBE_STATUS -eq 0 ]; then
        echo "Force recreating Minikube cluster..."
        minikube delete
    fi
    
    echo "Starting Minikube..."
    minikube start --driver=docker --memory=max --disk-size=20g -v=8 --alsologtostderr
    
    # Check if minikube started successfully
    if [ $? -ne 0 ]; then
        echo "Error: Failed to start Minikube"
        exit 1
    fi
    
    # Enable necessary addons
    echo "Enabling Minikube addons..."
    minikube addons enable ingress
    minikube addons enable metrics-server
    minikube addons enable dashboard
fi

# Create necessary directories
echo "Setting up directory structure..."
directories=(
    "k8s/deployments"
    "k8s/storage"
    "k8s/secrets"
    "k8s/jobs"
)

for dir in "${directories[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "Created directory: $dir"
    fi
done

# Generate JWT secrets if they don't exist
if [ ! -f "k8s/secrets/jwt-secret.yaml" ]; then
    echo "Generating JWT secrets..."
    JWT_SECRET=$(openssl rand -base64 32)
    JWT_REFRESH_SECRET=$(openssl rand -base64 32)
    
    cat > "k8s/secrets/jwt-secret.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-jwt-secret
type: Opaque
stringData:
  JWT_SECRET: "$JWT_SECRET"
  JWT_REFRESH_SECRET: "$JWT_REFRESH_SECRET"
EOF
fi

# Create database secrets if they don't exist
if [ ! -f "k8s/secrets/db-credentials.yaml" ]; then
    echo "Creating database credentials..."
    cat > "k8s/secrets/db-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:
  username: opentp
  password: samaral
  connection-string: "host=postgres dbname=opentp user=opentp password=samaral"
EOF
fi

# Create namespaces
echo "Creating namespaces..."
kubectl create namespace postgresql --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace redis --dry-run=client -o yaml | kubectl apply -f -

# Apply secrets
echo "Applying secrets..."
kubectl apply -f k8s/secrets/jwt-secret.yaml
kubectl apply -f k8s/secrets/db-credentials.yaml

# Set up hosts file entry
MINIKUBE_IP=$(minikube ip)
HOSTS_FILE="/etc/hosts"
if ! grep -q "trading.local" "$HOSTS_FILE"; then
    echo "Adding trading.local to hosts file..."
    echo "Run the following command to update your hosts file:"
    echo "sudo sh -c \"echo '$MINIKUBE_IP trading.local' >> $HOSTS_FILE\""
fi

echo "Setup complete! Your local Kubernetes environment is ready."
echo "Minikube IP: $MINIKUBE_IP"
echo ""
echo "Next steps:"
echo "1. Run './scripts/setup/02-build-images.sh' to build service images"
echo "2. Run './scripts/setup/03-deploy-services.sh' to deploy all services"
echo "3. Access the application at http://trading.local"