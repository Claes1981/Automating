#!/bin/bash
set -euo pipefail

################################################################################
# Azure VM Custom Data Script
# Installs and configures nginx web server on VM boot
################################################################################

log_info() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

update_system() {
  log_info "Updating system packages..."
  if ! apt update; then
    log_error "Failed to update package lists"
    return 1
  fi
}

install_nginx() {
  log_info "Installing nginx..."
  if ! apt install nginx -y; then
    log_error "Failed to install nginx"
    return 1
  fi
  log_info "nginx installed successfully"
}

start_nginx() {
  log_info "Starting and enabling nginx service..."
  if ! systemctl enable nginx; then
    log_error "Failed to enable nginx service"
    return 1
  fi
  
  if ! systemctl start nginx; then
    log_error "Failed to start nginx service"
    return 1
  fi
  
  log_info "nginx service started and enabled"
}

verify_nginx() {
  log_info "Verifying nginx installation..."
  if systemctl is-active --quiet nginx; then
    log_info "nginx is running"
    return 0
  else
    log_error "nginx is not running"
    return 1
  fi
}

main() {
  log_info "=========================================="
  log_info "Starting nginx setup on Azure VM"
  log_info "=========================================="
  
  update_system || exit 1
  install_nginx || exit 1
  start_nginx || exit 1
  verify_nginx || exit 1
  
  log_info "=========================================="
  log_info "nginx setup completed successfully"
  log_info "=========================================="
}

main
