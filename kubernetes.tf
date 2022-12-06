terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.20.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.1"
    }
  }
}

# Get terraform state from the EKS cluster provision project
data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket         = "terraform-wy"
    key            = "learn-terraform-kubernetes"
    region         = "us-west-2"
    dynamodb_table = "dynamodb-state-locking"
  }
}

# Retrieve EKS cluster information
provider "aws" {
  region = data.terraform_remote_state.eks.outputs.region
}

data "aws_eks_cluster" "cluster" {
  name = data.terraform_remote_state.eks.outputs.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      data.aws_eks_cluster.cluster.name
    ]
  }
}

resource "kubernetes_deployment" "petstore" {
  metadata {
    name = "scalable-api-example"
    labels = {
      App = "ScalableApiExample"
    }
  }

  spec {
    # Comment out the replicas setting so that HPA (Horizontal Pod AutoScaler) would take care of the scaling
    # replicas = 2
    selector {
      match_labels = {
        App = "ScalableApiExample"
      }
    }
    template {
      metadata {
        labels = {
          App = "ScalableApiExample"
        }
      }
      spec {
        container {
          image = "openapitools/openapi-petstore"
          name  = "example"

          port {
            container_port = 8080
          }

          resources {
            limits = {
              cpu    = "0.8"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }
}

# Auto scaling with Horizontal Pod Autoscaler, it requires metric server on the cluster
# https://docs.aws.amazon.com/eks/latest/userguide/metrics-server.html
resource "kubernetes_horizontal_pod_autoscaler_v2beta2" "petstore" {
  metadata {
    name = "api-hpa"
  }
  spec {
    min_replicas = 1
    max_replicas = 10

    scale_target_ref {
      api_version = "apps/v1"
      kind = "Deployment"
      name = kubernetes_deployment.petstore.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 75
        }
      }
    }

    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type          = "AverageValue"
          average_value = "400Mi"
        }
      }
    }
  }
}

resource "kubernetes_service" "petstore" {
  metadata {
    name = "api-example"
  }
  spec {
    selector = {
      App = kubernetes_deployment.petstore.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 8080
    }

    type = "LoadBalancer"
  }
}

output "lb_ip" {
  value = kubernetes_service.petstore.status.0.load_balancer.0.ingress.0.hostname
}
