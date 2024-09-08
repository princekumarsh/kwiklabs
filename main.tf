# main.tf

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
  backend "gcs" {
    bucket = "qwiklabs-gcp-03-6ffc66ee760a-bucket-tfstate"
    prefix = ""  # Remove the prefix to store at root level
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Cloud SQL Instance
resource "google_sql_database_instance" "cepf_instance" {
  name             = "cepf-instance"
  database_version = "POSTGRES_14"
  region           = var.region

  settings {
    tier = "db-f1-micro"
  }

  deletion_protection = false
}

resource "google_sql_database" "cepf_db" {
  name     = "cepf-db"
  instance = google_sql_database_instance.cepf_instance.name
}

resource "google_sql_user" "postgres" {
  name     = "postgres"
  instance = google_sql_database_instance.cepf_instance.name
  password = "postgres"
}

# Managed Instance Group
resource "google_compute_instance_template" "cepf_template" {
  name        = "cepf-template"
  description = "This template is used to create app server instances."

  tags = ["allow-health-check"]

  instance_description = "description assigned to instances"
  machine_type         = "e2-medium"
  can_ip_forward       = false

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network = "default"
    access_config {
      // Ephemeral public IP
    }
  }

  metadata_startup_script = file("${path.module}/startup-script.sh")

  service_account {
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_instance_group_manager" "cepf_mig" {
  name = "cepf-infra-lb-group1-mig"

  base_instance_name = "cepf-mig"
  zone               = "${var.region}-b"

  version {
    instance_template = google_compute_instance_template.cepf_template.id
  }

  target_size = 2

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.id
    initial_delay_sec = 300
  }
}

resource "google_compute_autoscaler" "cepf_autoscaler" {
  name   = "cepf-autoscaler"
  zone   = "${var.region}-b"
  target = google_compute_instance_group_manager.cepf_mig.id

  autoscaling_policy {
    max_replicas    = 4
    min_replicas    = 2
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }
  }
}

# Health check
resource "google_compute_health_check" "autohealing" {
  name                = "autohealing-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10

  http_health_check {
    request_path = "/"
    port         = "80"
  }
}

# Load Balancer
resource "google_compute_global_forwarding_rule" "cepf_infra_lb" {
  name       = "cepf-infra-lb"
  target     = google_compute_target_http_proxy.cepf_infra_lb_proxy.id
  port_range = "80"
}

resource "google_compute_target_http_proxy" "cepf_infra_lb_proxy" {
  name    = "cepf-infra-lb-proxy"
  url_map = google_compute_url_map.cepf_infra_lb_url_map.id
}

resource "google_compute_url_map" "cepf_infra_lb_url_map" {
  name            = "cepf-infra-lb-url-map"
  default_service = google_compute_backend_service.cepf_infra_lb_backend_default.id
}

resource "google_compute_backend_service" "cepf_infra_lb_backend_default" {
  name                  = "cepf-infra-lb-backend-default"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 10
  health_checks         = [google_compute_health_check.autohealing.id]
  backend {
    group           = google_compute_instance_group_manager.cepf_mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# Cloud NAT
resource "google_compute_router" "router" {
  name    = "cepf-router"
  region  = var.region
  network = "default"
}

resource "google_compute_router_nat" "nat" {
  name                               = "cepf-router-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}