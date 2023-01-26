terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.6.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.12.1"
    }
  }
}

variable "use_kubeconfig" {
  type        = bool
  sensitive   = true
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host. This
  is likely not your local machine unless you are using `coder server --dev.`

  EOF
}

variable "workspaces_namespace" {
  description = <<-EOF
  Kubernetes namespace to deploy the workspace into

  EOF
  default     = ""

}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}


variable "cpu" {
  description = "CPU (__ cores)"
  default     = 1
  validation {
    condition = contains([
      "1",
      "2",
      "4",
      "6",
      "8"
    ], var.cpu)
    error_message = "Invalid cpu!"
  }
}

variable "memory" {
  description = "Memory (__ GB)"
  default     = 2
  validation {
    condition = contains([
      "2",
      "4",
      "6",
      "8",
      "10",
      "12"
    ], var.memory)
    error_message = "Invalid memory!"
  }
}

variable "disk_size" {
  description = "Disk size (__ GB)"
  default     = 10
}

variable "dotfiles_uri" {
  description = <<-EOF
  Dotfiles repo URI (optional)

  see https://dotfiles.github.io
  EOF
  default     = "git@github.com:sharkymark/dotfiles.git"
}

resource "coder_agent" "dev" {
  os             = "linux"
  arch           = "amd64"
  dir            = "/home/coder"
  startup_script = <<EOF
    #!/bin/sh

    ${var.dotfiles_uri != "" ? "coder dotfiles -y ${var.dotfiles_uri} &" : ""}

    # clone 2 php repos
    mkdir -p ~/.ssh
    ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
    git clone --progress git@github.com:sharkymark/original_php.git
    git clone --progress git@github.com:sharkymark/php_helloworld.git

    # install VS Code extensions for PHP development and debugging
    SERVICE_URL=https://open-vsx.org/vscode/gallery ITEM_URL=https://open-vsx.org/vscode/item code-server --install-extension KnisterPeter.vscode-github &

    SERVICE_URL=https://open-vsx.org/vscode/gallery ITEM_URL=https://open-vsx.org/vscode/item code-server --install-extension felixfbecker.php-debug &

    # Start code-server
    code-server --auth none --port 13337 &

    # start PHP servers
    cd ~/original_php
    setsid /usr/bin/php -S 0.0.0.0:1026 -t . >/home/coder/phpapp2.log 2>&1 < /home/coder/phpapp2.log & 

    cd ~/php_helloworld
    setsid /usr/bin/php -S 0.0.0.0:1027 -t . >/home/coder/phpapp1.log 2>&1 < /home/coder/phpapp1.log & 

  EOF
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.dev.id
  slug         = "code-server"
  display_name = "VS Code"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }

}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home-directory
  ]
  metadata {
    name      = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = var.workspaces_namespace
  }
  spec {
    security_context {
      run_as_user = 1000
      fs_group    = 1000
    }
    container {
      name              = "dev"
      image             = "docker.io/marktmilligan/phpstorm-vscode:latest"
      image_pull_policy = "Always"
      command           = ["sh", "-c", coder_agent.dev.init_script]
      security_context {
        run_as_user = "1000"
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.dev.token
      }
      resources {
        requests = {
          cpu    = "250m"
          memory = "250Mi"
        }
        limits = {
          cpu    = "${var.cpu}"
          memory = "${var.memory}G"
        }
      }
      volume_mount {
        mount_path = "/home/coder"
        name       = "home-directory"
      }
    }
    volume {
      name = "home-directory"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home-directory.metadata.0.name
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "home-directory" {
  metadata {
    name      = "coder-pvc-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = var.workspaces_namespace
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${var.disk_size}Gi"
      }
    }
  }
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_pod.main[0].id
  item {
    key   = "kubernetes namespace"
    value = var.workspaces_namespace
  }
  item {
    key   = "CPU (limits, requests)"
    value = "${var.cpu} cores, ${kubernetes_pod.main[0].spec[0].container[0].resources[0].requests.cpu}"
  }
  item {
    key   = "memory (limits, requests)"
    value = "${var.memory}GB, ${kubernetes_pod.main[0].spec[0].container[0].resources[0].requests.memory}"
  }
  item {
    key   = "image"
    value = kubernetes_pod.main[0].spec[0].container[0].image
  }
  item {
    key   = "container image pull policy"
    value = kubernetes_pod.main[0].spec[0].container[0].image_pull_policy
  }
  item {
    key   = "disk"
    value = "${var.disk_size}GiB"
  }
  item {
    key   = "volume"
    value = kubernetes_pod.main[0].spec[0].container[0].volume_mount[0].mount_path
  }
  item {
    key   = "security context - container"
    value = "run_as_user ${kubernetes_pod.main[0].spec[0].container[0].security_context[0].run_as_user}"
  }
  item {
    key   = "security context - pod"
    value = "run_as_user ${kubernetes_pod.main[0].spec[0].security_context[0].run_as_user} fs_group ${kubernetes_pod.main[0].spec[0].security_context[0].fs_group}"
  }
}
