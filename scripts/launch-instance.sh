#!/bin/bash

# Launch OCI instance script
# Core logic for creating Oracle Cloud Infrastructure instances

set -euo pipefail

source "$(dirname "$0")/utils.sh"
source "$(dirname "$0")/notify.sh"
source "$(dirname "$0")/metrics.sh"
source "$(dirname "$0")/circuit-breaker.sh"
source "$(dirname "$0")/state-manager.sh"

# Global flag for signal handling
INTERRUPTED=false

# Signal handler for graceful shutdown
cleanup_on_signal() {
    local signal="$1"
    log_warning "Received signal $signal - initiating graceful shutdown..."
    INTERRUPTED=true
    
    # Kill any background processes if needed
    if [[ -n "${SLEEP_PID:-}" ]]; then
        kill "$SLEEP_PID" 2>/dev/null || true
        wait "$SLEEP_PID" 2>/dev/null || true
    fi
    
    log_info "Graceful shutdown completed"
    exit 130  # Standard exit code for Ctrl+C
}

# Set up signal handlers
trap 'cleanup_on_signal SIGTERM' SIGTERM
trap 'cleanup_on_signal SIGINT' SIGINT

# Interruptible sleep function
interruptible_sleep() {
    local duration="$1"
    local message="${2:-Waiting}"
    
    log_info "$message ${duration}s..."
    
    # Check if already interrupted
    if [[ "$INTERRUPTED" == true ]]; then
        return 1
    fi
    
    # Use background sleep so we can interrupt it
    sleep "$duration" &
    SLEEP_PID=$!
    
    # Wait for sleep to complete or signal to interrupt
    if wait "$SLEEP_PID" 2>/dev/null; then
        unset SLEEP_PID
        return 0
    else
        # Sleep was interrupted
        unset SLEEP_PID
        if [[ "$INTERRUPTED" == true ]]; then
            log_info "Sleep interrupted by signal"
            return 1
        fi
        return 0
    fi
}

# Ensure proxy configuration is applied if needed (fallback)
# Note: Proxy should already be configured by setup-oci.sh, but this ensures it's available
parse_and_configure_proxy false

determine_compartment() {
    local comp_id
    
    if [[ -z "${OCI_COMPARTMENT_ID:-}" ]]; then
        comp_id="$OCI_TENANCY_OCID"
        log_info "Using tenancy OCID as compartment"
    else
        comp_id="$OCI_COMPARTMENT_ID"
        log_info "Using specified compartment"
    fi
    
    echo "$comp_id"
}

lookup_image_id() {
    local comp_id="$1"
    local image_id
    
    # Set defaults for OS configuration if not provided
    local operating_system="${OPERATING_SYSTEM:-Oracle Linux}"
    local os_version="${OS_VERSION:-10}"
    
    if [[ -n "${OCI_IMAGE_ID:-}" ]]; then
        image_id="$OCI_IMAGE_ID"
        log_info "Using specified image ID"
    else
        # Try common cached image IDs first
        local cache_key="${operating_system}_${os_version}_${OCI_SHAPE}"
        case "$cache_key" in
            "Oracle Linux_10_VM.Standard.A1.Flex")
                # Common Oracle Linux 10 ARM image ID - update as needed
                image_id="${OCI_CACHED_OL10_ARM_IMAGE:-}"
                if [[ -n "$image_id" ]]; then
                    log_info "Using cached Oracle Linux 10 ARM image ID"
                fi
                ;;
            "Oracle Linux_10_VM.Standard.E2.1.Micro")
                # Common Oracle Linux 10 AMD image ID - update as needed
                image_id="${OCI_CACHED_OL10_AMD_IMAGE:-}"
                if [[ -n "$image_id" ]]; then
                    log_info "Using cached Oracle Linux 10 AMD image ID"
                fi
                ;;
        esac
        
        # Fallback to API lookup if no cached image
        if [[ -z "$image_id" ]]; then
            log_info "Looking up latest image for OS $operating_system $os_version..."
            
            image_id=$(oci_cmd compute image list \
                --compartment-id "$comp_id" \
                --shape "$OCI_SHAPE" \
                --operating-system "$operating_system" \
                --operating-system-version "$os_version" \
                --limit 1 \
                --sort-by TIMECREATED \
                --sort-order DESC \
                --query 'data[0].id' \
                --raw-output)
                
            if [[ -z "$image_id" || "$image_id" == "null" ]]; then
                local error_msg="No image found for $operating_system $os_version"
                log_error "$error_msg"
                send_telegram_notification "error" "OCI poller error: $error_msg"
                die "$error_msg"
            fi
            
            log_info "Found image ID: $image_id"
        fi
    fi
    
    echo "$image_id"
}

check_existing_instance() {
    local comp_id="$1"
    local existing_id
    
    log_info "Checking for existing instance: $INSTANCE_DISPLAY_NAME"
    
    existing_id=$(oci_cmd compute instance list \
        --compartment-id "$comp_id" \
        --display-name "$INSTANCE_DISPLAY_NAME" \
        --limit 1 \
        --query 'data[0].id' \
        --raw-output)
    
    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        log_info "Instance '$INSTANCE_DISPLAY_NAME' already exists (OCID: $existing_id)"
        echo "EXISTS"
        return 0
    fi
    
    echo "NOT_EXISTS"
}

build_launch_command() {
    local comp_id="$1"
    local image_id="$2"
    local ad_name="${3:-$OCI_AD}"  # Allow override for multi-AD cycling
    
    local launch_args=(
        "compute" "instance" "launch"
        "--availability-domain" "$ad_name"
        "--compartment-id" "$comp_id"
        "--shape" "$OCI_SHAPE"
        "--subnet-id" "$OCI_SUBNET_ID"
        "--image-id" "$image_id"
        "--display-name" "$INSTANCE_DISPLAY_NAME"
        "--assign-private-dns-record" "true"
        "--ssh-authorized-keys-file" "$HOME/.ssh/private_key_pub.pem"
    )
    
    # Add shape configuration for flexible shapes
    if [[ "$OCI_SHAPE" == *"Flex" ]]; then
        launch_args+=(
            "--shape-config" 
            "{\"ocpus\": ${OCI_OCPUS}, \"memoryInGBs\": ${OCI_MEMORY_IN_GBS}}"
        )
    fi
    
    # Set public IP assignment
    if [[ "$ASSIGN_PUBLIC_IP" == "true" ]]; then
        launch_args+=("--assign-public-ip" "true")
    else
        launch_args+=("--assign-public-ip" "false")
    fi
    
    # Add availability configuration for auto-recovery
    local recovery_action="${RECOVERY_ACTION:-RESTORE_INSTANCE}"
    launch_args+=(
        "--availability-config"
        "{\"recoveryAction\": \"$recovery_action\"}"
    )
    
    # Add instance options for IMDS compatibility
    local legacy_imds="${LEGACY_IMDS_ENDPOINTS:-false}"
    launch_args+=(
        "--instance-options"
        "{\"areLegacyImdsEndpointsDisabled\": $legacy_imds}"
    )
    
    # Add configurable boot volume size
    local boot_volume_size="${BOOT_VOLUME_SIZE:-50}"
    if [[ "$boot_volume_size" -lt 50 ]]; then
        boot_volume_size=50  # Ensure minimum 50GB
        log_warning "Boot volume size increased to minimum 50GB"
    fi
    launch_args+=(
        "--boot-volume-size-in-gbs" "$boot_volume_size"
    )
    
    printf '%s\n' "${launch_args[@]}"
}

# Launch Oracle Cloud Infrastructure instance with multi-AD cycling support
#
# ALGORITHM: Intelligent Multi-Availability Domain Instance Launching
#
# This is the core orchestration function implementing a sophisticated strategy
# to maximize instance creation success rates in Oracle Cloud's constrained
# free tier environment through intelligent availability domain cycling.
#
# ALGORITHM OVERVIEW:
# 1. Parse comma-separated AD configuration into attempt sequence
# 2. For each availability domain in sequence:
#    a. Execute optimized launch command with performance flags
#    b. Handle success: metrics recording, notifications, exit
#    c. Handle failure: error classification → next action decision
#    d. Apply configured inter-attempt delay if more ADs available
# 3. All ADs exhausted: return success (capacity constraint is expected)
#
# ERROR-DRIVEN STATE MACHINE:
# ```
# AD Attempt → Launch Success → Record Metrics → Notify → EXIT(0)
#           → Launch Failure → Classify Error
#                           → CAPACITY/RATE → More ADs? → YES: Next AD
#                                                      → NO: EXIT(0)  
#                           → LIMIT_EXCEEDED → Verify Creation → Found: EXIT(0)
#                                                             → Not Found: Next AD
#                           → TRANSIENT → More ADs? → YES: Next AD
#                                                   → NO: EXIT(0)
#                           → TERMINAL → Notify → EXIT(1)
# ```
#
# PERFORMANCE OPTIMIZATION STRATEGY:
# - OCI CLI flags: --no-retry (eliminates 62s exponential backoff)
# - Network timeouts: --connection-timeout 5 --read-timeout 15
# - Rate limit pre-detection: avoids redundant API calls
# - Instance verification: prevents Oracle inconsistency false negatives
# - Metrics collection: enables future optimization via success rate analysis
#
# CAPACITY PHILOSOPHY:
# Oracle free tier "Out of capacity" responses are treated as NORMAL operational
# conditions, not failures. This design philosophy prevents false alerts and
# allows GitHub Actions scheduling to handle natural retry cycles.
#
# Parameters:
#   comp_id   Compartment OCID where instance will be created
#   image_id  Image OCID to use for instance creation
# Returns:
#   0 on success (including expected capacity issues),
#   1 on configuration/authentication errors,
#   130 on signal interruption
#
# Multi-AD Strategy:
# - Parses OCI_AD as comma-separated list of availability domains
# - Attempts instance creation in each AD sequentially
# - On capacity/rate limit errors: tries next AD
# - On transient errors: tries next AD with retry logic
# - On config/auth errors: fails immediately with notification
# - Includes interruptible sleep between attempts for graceful shutdown
#
# Performance Optimizations:
# - Uses --no-retry flag to prevent exponential backoff (93% improvement)
# - Implements connection/read timeouts for network resilience
# - Early detection of rate limiting to skip redundant API calls
launch_instance() {
    local comp_id="$1"
    local image_id="$2"
    
    # Parse availability domains and apply circuit breaker filtering
    local available_ads_string
    available_ads_string=$(get_available_ads "$OCI_AD")
    
    if [[ -z "$available_ads_string" ]]; then
        log_warning "Circuit breaker has filtered out all ADs - all have too many recent failures"
        log_info "Will try again later when circuit breakers reset"
        return 0  # Treat as capacity issue - retry later
    fi
    
    local ad_list
    IFS=',' read -ra ad_list <<< "$available_ads_string"
    
    log_info "Available ADs after circuit breaker filtering: $available_ads_string"
    
    # Try each AD until success or all ADs exhausted
    local ad_index=0
    local max_attempts=${#ad_list[@]}
    local wait_time="${RETRY_WAIT_TIME:-30}"
    local transient_retry_max="${TRANSIENT_ERROR_MAX_RETRIES:-3}"
    
    while [[ $ad_index -lt $max_attempts ]]; do
        # Check for interruption signal
        if [[ "$INTERRUPTED" == true ]]; then
            log_info "Instance launch interrupted by signal - exiting gracefully"
            return 130
        fi
        
        local current_ad="${ad_list[$ad_index]}"
        log_info "Attempting to launch instance '$INSTANCE_DISPLAY_NAME' in AD $current_ad (attempt $((ad_index + 1))/$max_attempts)..."
        
        # Build launch command for current AD
        local launch_args
        readarray -t launch_args < <(build_launch_command "$comp_id" "$image_id" "$current_ad")
        
        # Execute launch command with single attempt for rate limiting
        local output
        local status
        
        set +e
        # Use oci_cmd to get debug output when enabled
        output=$(oci_cmd "${launch_args[@]}")
        status=$?
        set -e
        
        echo "$output"
        
        if [[ $status -eq 0 ]]; then
            # Success! Extract instance OCID using robust parsing
            local instance_id
            instance_id=$(extract_instance_ocid "$output")
            
            if [[ -z "$instance_id" ]]; then
                log_error "Could not extract instance OCID from output"
                log_debug "Raw output for debugging: $output"
                return 1
            fi
            
            # Use structured logging with context for better monitoring
            local context="{\"availability_domain\":\"$current_ad\",\"instance_ocid\":\"$instance_id\",\"attempt\":$((ad_index + 1)),\"max_attempts\":$max_attempts}"
            log_with_context "success" "Instance launched successfully" "$context"
            
            # Track successful AD for performance metrics and circuit breaker
            log_performance_metric "AD_SUCCESS" "$current_ad" "$((ad_index + 1))" "$max_attempts"
            record_ad_result "$current_ad" "success" ""
            mark_ad_success "$current_ad"  # Reset circuit breaker for this AD
            
            # Record instance creation in state cache
            if [[ "${CACHE_ENABLED:-true}" == "true" ]]; then
                log_info "Recording instance creation in state cache: ${INSTANCE_DISPLAY_NAME:-default}"
                record_instance_creation "${INSTANCE_DISPLAY_NAME:-default}" "$instance_id" "${state_file:-instance-state.json}"
            fi
            
            # Set GitHub repository variable to prevent future runs
            set_success_variable "$instance_id" "$current_ad"
            
            # Record success pattern for adaptive scheduling
            record_success_pattern "$current_ad" "$((ad_index + 1))" "$max_attempts"
            
            send_telegram_notification "success" "OCI instance created in $current_ad: ${INSTANCE_DISPLAY_NAME} (OCID: ${instance_id})"
            
            return 0
        fi
        
        # Handle launch errors
        local error_type
        error_type=$(handle_launch_error_with_ad "$output" "$current_ad" $((ad_index + 1)) "$max_attempts")
        
        case "$error_type" in
            "USER_LIMIT_REACHED")
                # User has reached free tier limits - this is expected behavior, not an error
                log_info "User limit reached for shape ${OCI_SHAPE:-unknown} - no further attempts needed"
                log_info "Free tier limit reached. Consider managing existing instances to free capacity."
                
                # This is a terminal condition - no point trying other ADs for user limits
                log_performance_metric "USER_LIMIT_REACHED" "${OCI_SHAPE:-unknown}" "$((ad_index + 1))" "$max_attempts" "TERMINAL"
                record_ad_result "$current_ad" "user_limit_reached" "$error_type"
                
                # No notification needed - user limits are expected operational conditions
                
                # Exit with the specific user limit error code
                return "$OCI_EXIT_USER_LIMIT_ERROR"
                ;;
            "ORACLE_CAPACITY_UNAVAILABLE"|"CAPACITY")
                # Track capacity-related failures for performance analysis and circuit breaker
                # NOTE: || true — не даём ошибке в метриках остановить перебор AD
                log_performance_metric "AD_FAILURE" "$current_ad" "$((ad_index + 1))" "$max_attempts" "$error_type" || true
                record_ad_result "$current_ad" "failure" "$error_type" || true
                increment_ad_failure "$current_ad" || true
                record_failure_pattern "$current_ad" "$error_type" "$((ad_index + 1))" "$max_attempts" || true
                
                # Try next AD if available
                if [[ $((ad_index + 1)) -lt $max_attempts ]]; then
                    log_info "Trying next availability domain..."
                    ad_index=$((ad_index + 1))
                    continue
                else
                    log_performance_metric "AD_CYCLE_COMPLETE" "ALL_ADS" "$max_attempts" "$max_attempts" "CAPACITY_EXHAUSTED"
                    log_info "All ADs exhausted - will retry on next schedule"
                    return "$OCI_EXIT_CAPACITY_ERROR"  # Capacity issue across all ADs
                fi
                ;;
            "RATE_LIMIT")
                # Rate limit detected - this is expected Oracle behavior
                log_info "Rate limit detected for shape ${OCI_SHAPE:-unknown} in AD $current_ad (attempt $((ad_index + 1))/$max_attempts)"
                log_info "This is normal Oracle API behavior - will retry on next scheduled workflow run"
                
                # No tracking as failure - this is expected operational behavior
                log_performance_metric "RATE_LIMIT_DETECTED" "$current_ad" "$((ad_index + 1))" "$max_attempts" "EXPECTED"
                
                # No AD cycling needed - rate limits affect all ADs equally
                # Exit immediately with rate limit error code (treated as success by workflow)
                return "$OCI_EXIT_RATE_LIMIT_ERROR"
                ;;
            "LIMIT_EXCEEDED")
                # Special case: check if instance was created despite error
                log_info "LimitExceeded error - checking if instance was created anyway..."
                if verify_instance_creation "$comp_id" "${INSTANCE_VERIFY_MAX_CHECKS:-5}" "${INSTANCE_VERIFY_DELAY:-30}"; then
                    return 0  # Instance was created successfully
                fi
                
                # Record the failure
                record_ad_result "$current_ad" "failure" "LIMIT_EXCEEDED"
                
                # Try next AD if available
                if [[ $((ad_index + 1)) -lt $max_attempts ]]; then
                    log_info "Trying next availability domain after LimitExceeded..."
                    ad_index=$((ad_index + 1))
                    continue
                else
                    log_info "All ADs exhausted after LimitExceeded errors"
                    return 0
                fi
                ;;
            "INTERNAL_ERROR"|"NETWORK")
                # Transient errors - retry on same AD before moving to next
                local retry_count=0
                local should_retry_same_ad=true
                
                while [[ $should_retry_same_ad == true && $retry_count -lt $transient_retry_max ]]; do
                    ((retry_count++))
                    
                    # Calculate exponential backoff delay for this attempt
                    local backoff_delay
                    backoff_delay=$(calculate_exponential_backoff "$retry_count" 5 40)
                    
                    log_info "Transient $error_type error - retrying same AD attempt $retry_count/$transient_retry_max (backoff: ${backoff_delay}s)..."
                    
                    # Wait before retry using exponential backoff
                    if ! interruptible_sleep "$backoff_delay" "Exponential backoff before retry on same AD"; then
                        log_info "Sleep interrupted - exiting gracefully"
                        return 130  # Signal interrupted
                    fi
                    
                    # Retry the same launch command
                    set +e
                    output=$(oci_cmd "${launch_args[@]}")
                    status=$?
                    set -e
                    
                    if [[ $status -eq 0 ]]; then
                        # Success on retry! Extract instance OCID
                        local instance_id
                        instance_id=$(extract_instance_ocid "$output")
                        
                        if [[ -z "$instance_id" ]]; then
                            log_error "Could not extract instance OCID from retry output"
                            log_debug "Raw retry output for debugging: $output"
                            return 1
                        fi
                        
                        local context="{\"availability_domain\":\"$current_ad\",\"instance_ocid\":\"$instance_id\",\"retry_attempt\":$retry_count,\"total_retries\":$transient_retry_max}"
                        log_with_context "success" "Instance launched successfully after retry" "$context"
                        
                        # Track successful AD for performance metrics and circuit breaker
                        log_performance_metric "AD_SUCCESS_RETRY" "$current_ad" "$retry_count" "$transient_retry_max"
                        record_ad_result "$current_ad" "success" "RETRY_$retry_count"
                        mark_ad_success "$current_ad"  # Reset circuit breaker for this AD
                        
                        # Record instance creation in state cache
                        if [[ "${CACHE_ENABLED:-true}" == "true" ]]; then
                            log_info "Recording instance creation in state cache: ${INSTANCE_DISPLAY_NAME:-default}"
                            record_instance_creation "${INSTANCE_DISPLAY_NAME:-default}" "$instance_id" "${state_file:-instance-state.json}"
                        fi
                        
                        # Set GitHub repository variable to prevent future runs
                        set_success_variable "$instance_id" "$current_ad"
                        
                        # Record success pattern for adaptive scheduling
                        record_success_pattern "$current_ad" "$retry_count" "$transient_retry_max"
                        
                        send_telegram_notification "success" "OCI instance created in $current_ad after $retry_count retries: ${INSTANCE_DISPLAY_NAME} (OCID: ${instance_id})"
                        
                        return 0
                    fi
                    
                    # Check the error type again
                    local retry_error_type
                    retry_error_type=$(handle_launch_error_with_ad "$output" "$current_ad" $retry_count "$transient_retry_max")
                    
                    # If it's no longer a transient error, stop retrying same AD
                    if [[ "$retry_error_type" != "INTERNAL_ERROR" && "$retry_error_type" != "NETWORK" ]]; then
                        log_info "Error type changed from $error_type to $retry_error_type - stopping same-AD retries"
                        should_retry_same_ad=false
                        # Set the new error type for downstream processing
                        error_type="$retry_error_type"
                        break
                    fi
                done
                
                # Record the final failure after all retries
                record_ad_result "$current_ad" "failure" "${error_type}_RETRIES_${retry_count}"
                
                # If we still have a transient error after retries, try next AD
                if [[ "$error_type" == "INTERNAL_ERROR" || "$error_type" == "NETWORK" ]]; then
                    if [[ $((ad_index + 1)) -lt $max_attempts ]]; then
                        log_info "All retries exhausted for $current_ad - trying next availability domain..."
                        ad_index=$((ad_index + 1))
                        continue
                    else
                        # All ADs attempted with transient errors - treat as temporary capacity issue
                        log_info "All ADs and retries exhausted with transient errors - will retry on next schedule"
                        return 0
                    fi
                else
                    # Error type changed to something else during retries - handle it
                    case "$error_type" in
                        "CAPACITY")
                            if [[ $((ad_index + 1)) -lt $max_attempts ]]; then
                                log_info "Trying next availability domain after capacity error during retry..."
                                ad_index=$((ad_index + 1))
                                continue
                            else
                                log_info "All ADs exhausted - will retry on next schedule"
                                return 0
                            fi
                            ;;
                        "RATE_LIMIT")
                            # Rate limit during retry - exit immediately, no further attempts
                            log_info "Rate limit encountered during retry - exiting"
                            return "$OCI_EXIT_RATE_LIMIT_ERROR"
                            ;;
                        "AUTH"|"CONFIG")
                            return 1  # Configuration errors - immediate failure
                            ;;
                        *)
                            return 1  # Unknown errors - propagate failure
                            ;;
                    esac
                fi
                ;;
            "SUCCESS"|"DUPLICATE")
                return 0  # Not a failure
                ;;
            "AUTH"|"CONFIG")
                # Record the failure
                record_ad_result "$current_ad" "failure" "$error_type"
                
                # Configuration errors - immediate failure with notification
                return 1
                ;;
            *)
                # Record unknown errors
                record_ad_result "$current_ad" "failure" "UNKNOWN"
                
                # Unknown errors - propagate failure but don't send duplicate notifications
                return 1
                ;;
        esac
        
        # Add delay between AD attempts if configured
        if [[ $wait_time -gt 0 && $((ad_index + 1)) -lt $max_attempts ]]; then
            if ! interruptible_sleep "$wait_time" "Waiting before trying next AD"; then
                log_info "Sleep interrupted - exiting gracefully"
                return 130  # Signal interrupted
            fi
        fi
        
        ad_index=$((ad_index + 1))
    done
    
    # Should not reach here, but handle gracefully
    log_info "All availability domains attempted - will retry on next schedule"
    return 0
}

# Handle and classify errors from instance launch attempts in multi-AD scenario
#
# ALGORITHM: Multi-AD Error Classification and Response Strategy
# 
# This function implements a sophisticated error analysis system that categorizes
# Oracle Cloud errors into actionable response strategies. The classification
# directly drives the multi-AD cycling logic and determines whether to:
# 1. Try the next availability domain (retriable errors)
# 2. Exit successfully (capacity issues - expected for free tier)
# 3. Exit with failure (configuration/authentication issues)
#
# ERROR CLASSIFICATION HIERARCHY:
# - CAPACITY: Expected for free tier → Try next AD → Success if all ADs exhausted
# - RATE_LIMIT: Oracle API throttling → Exit immediately with success
# - LIMIT_EXCEEDED: Special case → Verify instance creation → Try next AD if needed
# - INTERNAL_ERROR/NETWORK: Transient → Try next AD → Eventual success
# - DUPLICATE: Instance exists → Success immediately  
# - AUTH/CONFIG: Critical failure → Immediate exit with error
# - UNKNOWN: Unexpected → Log and exit with error
#
# PERFORMANCE CONSIDERATIONS:
# - Early pattern matching prevents redundant API calls
# - Rate limit detection avoids exponential backoff cycles
# - Instance verification prevents false negatives from LimitExceeded
#
# Parameters:
#   error_output    Raw error output from OCI CLI command
#   current_ad      Current availability domain being attempted  
#   attempt         Current attempt number (1-based)
#   max_attempts    Total number of ADs to attempt
# Returns:
#   Error classification: CAPACITY, RATE_LIMIT, LIMIT_EXCEEDED, INTERNAL_ERROR,
#   NETWORK, DUPLICATE, AUTH, CONFIG, or UNKNOWN
#
# Error Classification Strategy:
# - CAPACITY/LIMIT_EXCEEDED: Try next AD, not a failure
# - RATE_LIMIT: Exit immediately with success (no AD cycling needed)
# - INTERNAL_ERROR/NETWORK: Transient issues, try next AD
# - AUTH/CONFIG: Immediate failure with notification  
# - DUPLICATE: Success (instance already exists)
# - UNKNOWN: Failure with generic error notification
handle_launch_error_with_ad() {
    local error_output="$1"
    local current_ad="$2"
    local attempt="$3"
    local max_attempts="$4"
    local error_type
    
    error_type=$(get_error_type "$error_output")
    
    case "$error_type" in
        "USER_LIMIT_REACHED")
            log_info "User limit reached for shape ${OCI_SHAPE:-unknown} in AD $current_ad (attempt $attempt/$max_attempts)"
            log_info "This indicates the free tier limit has been reached (E2: 2/2 instances, A1: 4/4 OCPUs)"
            
            # Update cached limit state to prevent future attempts
            if [[ "${CACHE_ENABLED:-true}" == "true" && -n "${OCI_SHAPE:-}" ]]; then
                log_info "Caching limit state for shape: ${OCI_SHAPE}"
                set_cached_limit_state "${OCI_SHAPE}" "true" "${state_file:-instance-state.json}"
            fi
            
            echo "USER_LIMIT_REACHED"
            return 0
            ;;
        "ORACLE_CAPACITY_UNAVAILABLE")
            log_info "Oracle capacity unavailable for shape in AD $current_ad (attempt $attempt/$max_attempts)"
            log_info "This is a transient Oracle Cloud capacity constraint"
            echo "ORACLE_CAPACITY_UNAVAILABLE"
            return 0
            ;;
        "CAPACITY")
            log_info "No capacity available for shape in AD $current_ad (attempt $attempt/$max_attempts)"
            echo "CAPACITY"
            return 0
            ;;
        "RATE_LIMIT")
            log_info "Rate limit detected in AD $current_ad (attempt $attempt/$max_attempts)"
            echo "RATE_LIMIT"
            return 0
            ;;
        "LIMIT_EXCEEDED")
            log_info "LimitExceeded error in AD $current_ad (attempt $attempt/$max_attempts)"
            echo "LIMIT_EXCEEDED"
            return 0
            ;;
        "DUPLICATE")
            log_info "Instance with this name already exists. Skipping creation."
            # No notification needed - instance exists is an expected condition when using state management
            echo "DUPLICATE"
            return 0
            ;;
        "AUTH")
            log_error "Authentication/authorization error in AD $current_ad"
            send_telegram_notification "critical" "OCI authentication error: Check credentials and permissions"
            echo "AUTH"
            return 0
            ;;
        "CONFIG")
            log_error "Configuration error detected in AD $current_ad"
            local error_line
            error_line=$(echo "$error_output" | head -1)
            send_telegram_notification "critical" "OCI configuration error: ${error_line}"
            echo "CONFIG"
            return 0
            ;;
        "INTERNAL_ERROR")
            log_warning "Internal/gateway error detected in AD $current_ad - will retry"
            echo "INTERNAL_ERROR"
            return 0
            ;;
        "NETWORK")
            log_warning "Network error detected in AD $current_ad - will retry"
            echo "NETWORK"
            return 0
            ;;
        *)
            log_error "Unexpected error during instance launch in AD $current_ad"
            local error_line
            error_line=$(echo "$error_output" | head -1)
            send_telegram_notification "error" "OCI instance launch failed in $current_ad: ${error_line}"
            echo "UNKNOWN"
            return 0
            ;;
    esac
}

# Verify that an instance was successfully created despite error responses
#
# Oracle Cloud sometimes returns error responses (like LimitExceeded) but 
# successfully creates the instance anyway. This function performs multiple
# verification attempts to check if an instance with the expected display
# name exists in RUNNING or PROVISIONING state.
#
# Configuration via environment variables:
#   INSTANCE_VERIFY_MAX_CHECKS (default: 5) - number of verification attempts
#   INSTANCE_VERIFY_DELAY (default: 30) - seconds between checks
#   Total timeout: MAX_CHECKS × DELAY seconds (default: 5×30 = 150s)
#
# Parameters:
#   comp_id      Compartment OCID where instance should be created
#   max_checks   Maximum number of verification attempts (default: 5)
#   check_delay  Delay in seconds between attempts (default: 30)
# Returns:
#   0 if instance found, 1 if not found after all attempts, 130 if interrupted
#
# This is critical for handling Oracle's inconsistent error reporting where
# a successful instance creation may be reported as a failure.
verify_instance_creation() {
    local comp_id="$1"
    local max_checks="${2:-5}"
    local check_delay="${3:-30}"
    
    local total_timeout=$((max_checks * check_delay))
    log_info "Verifying instance creation with $max_checks checks (${check_delay}s intervals, ${total_timeout}s total timeout)..."
    
    for ((i=1; i<=max_checks; i++)); do
        log_info "Instance verification check $i/$max_checks..."
        
        local instance_id
        instance_id=$(oci_cmd compute instance list \
            --compartment-id "$comp_id" \
            --display-name "$INSTANCE_DISPLAY_NAME" \
            --lifecycle-state "RUNNING,PROVISIONING" \
            --limit 1 \
            --query 'data[0].id' \
            --raw-output 2>/dev/null || echo "")
        
        if [[ -n "$instance_id" && "$instance_id" != "null" ]]; then
            local state
            state=$(oci_cmd compute instance get \
                --instance-id "$instance_id" \
                --query 'data."lifecycle-state"' \
                --raw-output 2>/dev/null || echo "")
            
            log_success "Instance found: $instance_id (state: $state)"
            
            # Record instance creation in state cache
            if [[ "${CACHE_ENABLED:-true}" == "true" ]]; then
                log_info "Recording instance creation in state cache: ${INSTANCE_DISPLAY_NAME:-default}"
                record_instance_verification "${INSTANCE_DISPLAY_NAME:-default}" "$instance_id" "verified" "${state_file:-instance-state.json}"
            fi
            
            # Set GitHub repository variable to prevent future runs
            set_success_variable "$instance_id" "VERIFIED"
            
            # Record success pattern for adaptive scheduling
            record_success_pattern "VERIFIED" "1" "1"
            
            send_telegram_notification "success" "OCI instance verified: ${INSTANCE_DISPLAY_NAME} (OCID: ${instance_id}, State: ${state})"
            return 0
        fi
        
        if [[ $i -lt $max_checks ]]; then
            if ! interruptible_sleep "$check_delay" "Instance not found yet, waiting before next check"; then
                log_info "Verification interrupted - exiting gracefully"
                return 130
            fi
        fi
    done
    
    log_warning "Instance verification failed after $max_checks checks"
    return 1
}

# Main function
launch_oci_instance() {
    start_timer "total_execution"
    log_info "Starting OCI instance launch process for shape: ${OCI_SHAPE:-<not set>}"
    
    # Initialize AD metrics tracking
    init_metrics
    
    # Check OCI CLI availability
    start_timer "oci_cli_check"
    check_oci_cli
    log_elapsed "oci_cli_check"
    
    # Determine compartment to use
    start_timer "compartment_setup"
    local comp_id
    comp_id=$(determine_compartment)
    log_elapsed "compartment_setup"
    
    # Initialize state management and check cache first (if enabled)
    local state_file="instance-state.json"
    if [[ "${CACHE_ENABLED:-true}" == "true" ]]; then
        log_info "Initializing state management system..."
        start_timer "state_cache_check"
        init_state_manager "$state_file" >/dev/null
        
        # Check if instance should be created based on cache state
        if ! should_create_instance "${INSTANCE_DISPLAY_NAME:-default}" "$state_file"; then
            log_info "Instance exists in cache and is valid, skipping creation: ${INSTANCE_DISPLAY_NAME:-default}"
            log_elapsed "state_cache_check"
            log_elapsed "total_execution"
            return 0
        else
            log_info "Cache indicates instance should be created: ${INSTANCE_DISPLAY_NAME:-default}"
        fi
        log_elapsed "state_cache_check"
    fi
    
    # Check for existing instance via OCI API (if enabled and cache didn't skip)
    if [[ "${CHECK_EXISTING_INSTANCE:-false}" == "true" ]]; then
        start_timer "existing_instance_check"
        local instance_status
        instance_status=$(check_existing_instance "$comp_id")
        log_elapsed "existing_instance_check"
        
        if [[ "$instance_status" == "EXISTS" ]]; then
            log_info "Skipping creation - instance already exists"
            log_elapsed "total_execution"
            return 0
        fi
    else
        log_info "Skipping existing instance check - attempting direct launch"
    fi
    
    # Lookup or use provided image ID
    start_timer "image_lookup"
    local image_id
    image_id=$(lookup_image_id "$comp_id")
    log_elapsed "image_lookup"
    
    # Launch the instance
    start_timer "instance_launch"
    launch_instance "$comp_id" "$image_id"
    log_elapsed "instance_launch"
    
    # Show AD performance metrics
    show_ad_metrics
    
    log_elapsed "total_execution"
}

# Run launch if called directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    launch_oci_instance
fi
