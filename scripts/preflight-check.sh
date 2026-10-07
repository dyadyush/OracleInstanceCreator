#!/bin/bash

# Production Environment Validation (Preflight Check)
# Validates all configuration and dependencies before instance creation

set -euo pipefail

source "$(dirname "$0")/utils.sh"

# Track validation status
VALIDATION_ERRORS=0

# Display validation header
echo "========================================"
echo "Oracle Instance Creator - Preflight Check"
echo "========================================"
echo ""

# Increment error counter and log error
validation_error() {
    local message="$1"
    ((VALIDATION_ERRORS++))
    log_error "✗ $message"
}

# Log successful validation
validation_error() {
    local message="$1"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    log_error "✗ $message"
}

# Log warning (non-blocking)
validation_warning() {
    local message="$1"
    log_warning "⚠ $message"
}

# Check required environment variable
check_required_var() {
    local var_name="$1"
    local description="$2"
    
    if [[ -z "${!var_name:-}" ]]; then
        validation_error "$description: $var_name is not set"
        return 1
    else
        validation_success "$description: $var_name is configured"
        return 0
    fi
}

# Validate OCID format
validate_ocid_var() {
    local var_name="$1"
    local description="$2"
    local ocid="${!var_name:-}"
    
    if [[ -z "$ocid" ]]; then
        validation_error "$description: $var_name is not set"
        return 1
    fi
    
    if is_valid_ocid "$ocid"; then
        validation_success "$description: $var_name has valid OCID format"
        return 0
    else
        validation_error "$description: $var_name has invalid OCID format: $ocid"
        return 1
    fi
}

log_info "1. Checking required GitHub secrets..."
echo ""

# OCI Configuration
check_required_var "OCI_USER_OCID" "OCI User OCID"
check_required_var "OCI_KEY_FINGERPRINT" "OCI Key Fingerprint"
check_required_var "OCI_TENANCY_OCID" "OCI Tenancy OCID"
check_required_var "OCI_REGION" "OCI Region"
check_required_var "OCI_PRIVATE_KEY" "OCI Private Key"

# Instance Configuration
# OCI_COMPARTMENT_ID is optional - falls back to tenancy if not specified
check_required_var "OCI_SUBNET_ID" "OCI Subnet ID"
check_required_var "INSTANCE_SSH_PUBLIC_KEY" "SSH Public Key"

# Telegram Configuration
check_required_var "TELEGRAM_TOKEN" "Telegram Bot Token"
check_required_var "TELEGRAM_USER_ID" "Telegram User ID"

echo ""
log_info "2. Validating OCID formats..."
echo ""

# Validate OCID formats
validate_ocid_var "OCI_USER_OCID" "User OCID"
validate_ocid_var "OCI_TENANCY_OCID" "Tenancy OCID"
# Validate compartment OCID if provided (falls back to tenancy if not)
if [[ -n "${OCI_COMPARTMENT_ID:-}" ]]; then
    validate_ocid_var "OCI_COMPARTMENT_ID" "Compartment OCID"
fi
validate_ocid_var "OCI_SUBNET_ID" "Subnet OCID"

# Validate image OCID if provided
if [[ -n "${OCI_IMAGE_ID:-}" ]]; then
    validate_ocid_var "OCI_IMAGE_ID" "Image OCID"
else
    validation_warning "Image OCID: Will be auto-detected (OCI_IMAGE_ID not set)"
fi

echo ""
log_info "3. Checking instance configuration..."
echo ""

# Instance shape validation
if [[ -n "${OCI_SHAPE:-}" ]]; then
    validation_success "Instance shape: $OCI_SHAPE"
    
    # Check for flexible shape configuration
    if [[ "$OCI_SHAPE" == *".Flex" ]]; then
        if [[ -n "${OCI_OCPUS:-}" && -n "${OCI_MEMORY_IN_GBS:-}" ]]; then
            validation_success "Flexible shape config: ${OCI_OCPUS} OCPUs, ${OCI_MEMORY_IN_GBS} GB RAM"
        else
            validation_error "Flexible shape requires OCI_OCPUS and OCI_MEMORY_IN_GBS"
        fi
    fi
else
    validation_error "Instance shape not specified (OCI_SHAPE)"
fi

# Availability domain validation
if [[ -n "${OCI_AD:-}" ]]; then
    # Check if it's multi-AD format
    if [[ "$OCI_AD" == *","* ]]; then
        IFS=',' read -ra ad_list <<< "$OCI_AD"
        validation_success "Multi-AD configuration: ${#ad_list[@]} domains"
        for ad in "${ad_list[@]}"; do
            if validate_availability_domain "$ad"; then
                log_info "  - $ad: Valid format"
            else
                validation_error "  - $ad: Invalid format"
            fi
        done
    else
        if validate_availability_domain "$OCI_AD"; then
            validation_success "Availability domain: $OCI_AD"
        else
            validation_error "Invalid availability domain format: $OCI_AD"
        fi
    fi
else
    validation_error "Availability domain not specified (OCI_AD)"
fi

# Operating system validation
if [[ -n "${OPERATING_SYSTEM:-}" ]]; then
    validation_success "Operating system: ${OPERATING_SYSTEM} ${OS_VERSION:-}"
else
    validation_error "Operating system not specified (OPERATING_SYSTEM)"
fi

echo ""
log_info "4. Checking system dependencies..."
echo ""

# OCI CLI availability
if command -v oci >/dev/null 2>&1; then
    validation_success "OCI CLI is installed ($(oci --version 2>/dev/null || echo 'version unknown'))"
else
    validation_error "OCI CLI is not available"
fi

# jq availability (optional but recommended)
if command -v jq >/dev/null 2>&1; then
    validation_success "jq is available ($(jq --version 2>/dev/null || echo 'version unknown'))"
else
    validation_warning "jq not available - will use regex fallback for JSON parsing"
fi

# curl availability (for Telegram notifications)
if command -v curl >/dev/null 2>&1; then
    validation_success "curl is available ($(curl --version 2>/dev/null | head -1 || echo 'version unknown'))"
else
    validation_error "curl is not available (required for Telegram notifications)"
fi

echo ""
log_info "5. Validating notification configuration..."
echo ""

if [[ -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_USER_ID:-}" ]]; then
    validation_success "Telegram credentials configured"
else
    validation_warning "Telegram credentials not configured"
fi

echo ""
echo "========================================"
echo "Preflight Check Results"
echo "========================================"

if [[ $VALIDATION_ERRORS -eq 0 ]]; then
    log_success "✓ All validations passed! Ready for production deployment"
    exit 0
else
    log_error "✗ Found $VALIDATION_ERRORS validation errors"
    log_error "Please fix the above issues before deploying"
    exit 1
fi
