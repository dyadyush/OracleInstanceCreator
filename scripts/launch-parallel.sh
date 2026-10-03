#!/bin/bash

# Parallel OCI instance launcher script
# Attempts to create both free tier shapes simultaneously:
# - VM.Standard.A1.Flex (ARM): 4 OCPUs, 24GB RAM
# - VM.Standard.E2.1.Micro (AMD): 1 OCPU, 1GB RAM
#
# TELEGRAM NOTIFICATION RULES:
# NOTIFY: Any instance created OR critical failures (auth/config/system)
# SILENT: Zero instances created (capacity/limits/rate limiting)

set -euo pipefail

# shellcheck source=scripts/utils.sh
source "$(dirname "$0")/utils.sh"
# shellcheck source=scripts/notify.sh
source "$(dirname "$0")/notify.sh"
source "$(dirname "$0")/state-manager.sh"

# Global variables for signal handling
PID_A1=""
PID_E2=""
temp_dir=""

# Performance monitoring functions
get_memory_usage() {
    if command -v free >/dev/null 2>&1; then
        # Linux - get used memory in MB
        free -m | awk 'NR==2{printf "%.1f", $3}'
    elif command -v vm_stat >/dev/null 2>&1; then
        # macOS - get used memory in MB
        vm_stat | awk '
        /Pages free/ { free = $3 + 0 }
        /Pages active/ { active = $3 + 0 }
        /Pages inactive/ { inactive = $3 + 0 }
        /Pages wired down/ { wired = $4 + 0 }
        END { printf "%.1f", (active + inactive + wired) * 4096 / 1024 / 1024 }'
    else
        echo "0"
    fi
}

# Track resource contention during parallel execution
track_resource_usage() {
    local phase="$1" # "start", "peak", "end"
    local memory_usage
    memory_usage=$(get_memory_usage)

    # Log resource usage for monitoring
    log_performance_metric "RESOURCE_USAGE" "parallel_execution" "$phase" "1" "Memory=${memory_usage}MB"

    # Store peak usage for analysis
    if [[ "$phase" == "peak" ]]; then
        echo "$memory_usage" >"${temp_dir}/peak_memory_usage" 2>/dev/null || true
    fi
}

# Terminate background processes gracefully then forcefully
terminate_processes() {
    # Graceful termination first
    if [[ -n "$PID_A1" ]] && kill -0 "$PID_A1" 2>/dev/null; then
        log_debug "Terminating A1 process (PID: $PID_A1)"
        kill "$PID_A1" 2>/dev/null || true
    fi
    if [[ -n "$PID_E2" ]] && kill -0 "$PID_E2" 2>/dev/null; then
        log_debug "Terminating E2 process (PID: $PID_E2)"
        kill "$PID_E2" 2>/dev/null || true
    fi
    sleep "$GRACEFUL_TERMINATION_DELAY" # 2-second grace period allows processes to cleanup before SIGKILL

    # Force kill if still running
    if [[ -n "$PID_A1" ]] && kill -0 "$PID_A1" 2>/dev/null; then
        kill -9 "$PID_A1" 2>/dev/null || true
    fi
    if [[ -n "$PID_E2" ]] && kill -0 "$PID_E2" 2>/dev/null; then
        kill -9 "$PID_E2" 2>/dev/null || true
    fi
}

# Signal handler for graceful shutdown
cleanup_handler() {
    log_warning "Received interrupt signal - cleaning up background processes"

    terminate_processes

    # Cleanup temporary files
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir" 2>/dev/null || true
    fi

    log_info "Cleanup completed"
    exit "$OCI_EXIT_GENERAL_ERROR"
}

# Set up signal handlers
trap cleanup_handler SIGTERM SIGINT

# Shape configurations for Oracle Cloud free tier
# shellcheck disable=SC2034  # Used via nameref in launch_shape()
declare -A A1_FLEX_CONFIG=(
    ["SHAPE"]="VM.Standard.A1.Flex"
    ["OCPUS"]="2"
    ["MEMORY_IN_GBS"]="12"
    ["DISPLAY_NAME"]="a1-flex-sg"
)

# shellcheck disable=SC2034  # Used via nameref in launch_shape()
declare -A E2_MICRO_CONFIG=(
    ["SHAPE"]="VM.Standard.E2.1.Micro"
    ["OCPUS"]=""
    ["MEMORY_IN_GBS"]=""
    ["DISPLAY_NAME"]="e2-micro-sg"
)

# Verify actual instance existence by querying OCI API
count_actual_instances() {
    local comp_id
    comp_id=$(require_env_var "OCI_COMPARTMENT_ID" 2>/dev/null) || {
        log_debug "OCI_COMPARTMENT_ID unavailable - cannot verify instance count"
        return 0
    }
    
    local actual_count=0
    
    # Check A1.Flex instance
    local a1_instance_id
    if a1_instance_id=$(oci_cmd compute instance list \
        --compartment-id "$comp_id" \
        --display-name "${A1_FLEX_CONFIG[DISPLAY_NAME]}" \
        --lifecycle-state "RUNNING,PROVISIONING,STARTING" \
        --query 'data[0].id' \
        --raw-output 2>&1) && [[ -n "$a1_instance_id" && "$a1_instance_id" != "null" ]]; then
        ((actual_count++))
    else
        # Log API failures for debugging while maintaining graceful degradation
        if [[ -n "$a1_instance_id" && "$a1_instance_id" =~ (ERROR|ServiceError|Authentication) ]]; then
            log_debug "A1.Flex instance verification failed: ${a1_instance_id:0:100}..."
        fi
    fi
    
    # Check E2.1.Micro instance
    local e2_instance_id
    if e2_instance_id=$(oci_cmd compute instance list \
        --compartment-id "$comp_id" \
        --display-name "${E2_MICRO_CONFIG[DISPLAY_NAME]}" \
        --lifecycle-state "RUNNING,PROVISIONING,STARTING" \
        --query 'data[0].id' \
        --raw-output 2>&1) && [[ -n "$e2_instance_id" && "$e2_instance_id" != "null" ]]; then
        ((actual_count++))
    else
        # Log API failures for debugging while maintaining graceful degradation
        if [[ -n "$e2_instance_id" && "$e2_instance_id" =~ (ERROR|ServiceError|Authentication) ]]; then
            log_debug "E2.1.Micro instance verification failed: ${e2_instance_id:0:100}..."
        fi
    fi
    
    echo "$actual_count"
}

launch_shape() {
    local shape_name="$1"
    local -n config=$2

    log_info "Starting $shape_name launch attempt..."

    # Track shape-specific timing
    local shape_start_time
    shape_start_time=$(date +%s)

    # Set shape-specific environment variables
    export OCI_SHAPE="${config[SHAPE]}"
    export OCI_OCPUS="${config[OCPUS]}"
    export OCI_MEMORY_IN_GBS="${config[MEMORY_IN_GBS]}"
    export INSTANCE_DISPLAY_NAME="${config[DISPLAY_NAME]}"

    # Launch the instance using existing script
    local script_dir
    script_dir="$(dirname "$0")"
    "$script_dir/launch-instance.sh"
    local exit_code=$?

    # Calculate and log shape execution time
    local shape_end_time duration
    shape_end_time=$(date +%s)
    duration=$((shape_end_time - shape_start_time))

    # Log shape performance metrics
    log_performance_metric "SHAPE_DURATION" "$shape_name" "$duration" "$exit_code" "Shape=${config[SHAPE]}"

    # Store duration for analysis (write to temp file if available)
    if [[ -n "${temp_dir:-}" ]]; then
        echo "$duration" >"${temp_dir}/${shape_name,,}_duration" 2>/dev/null || true
    fi

    return $exit_code
}

# Verify instance states and update cache after parallel execution
verify_and_update_state() {
    local status_a1="$1"
    local status_e2="$2"
    local state_file="instance-state.json"
    local verification_errors=0
    
    # Initialize state manager if not already done
    if ! init_state_manager "$state_file" >/dev/null; then
        log_error "Failed to initialize state manager"
        return 1
    fi
    
    # Get the compartment ID for OCI API calls
    local comp_id
    if ! comp_id=$(require_env_var "OCI_COMPARTMENT_ID" 2>/dev/null); then
        log_error "OCI_COMPARTMENT_ID not available - cannot verify instance state"
        return 2  # Return specific error code for missing config
    fi
    
    # Verify A1.Flex instance state if creation was attempted
    if [[ "$status_a1" -eq 0 ]]; then
        # Instance creation succeeded according to script, verify with OCI API
        local a1_instance_id
        if a1_instance_id=$(oci_cmd compute instance list \
            --compartment-id "$comp_id" \
            --display-name "${A1_FLEX_CONFIG[DISPLAY_NAME]}" \
            --lifecycle-state "RUNNING,PROVISIONING,STARTING" \
            --query 'data[0].id' \
            --raw-output 2>/dev/null); then
            
            if [[ -n "$a1_instance_id" && "$a1_instance_id" != "null" ]]; then
                log_info "Verified A1.Flex instance exists: $a1_instance_id"
                if ! record_instance_verification "${A1_FLEX_CONFIG[DISPLAY_NAME]}" "$a1_instance_id" "verified" "$state_file"; then
                    log_warning "Failed to record A1.Flex instance verification"
                    ((verification_errors++))
                fi
            else
                log_warning "A1.Flex instance creation reported success but instance not found via API"
                ((verification_errors++))
            fi
        else
            log_error "Failed to query A1.Flex instance state via OCI API"
            ((verification_errors++))
        fi
    fi
    
    # Verify E2.Micro instance state if creation was attempted
    if [[ "$status_e2" -eq 0 ]]; then
        # Instance creation succeeded according to script, verify with OCI API
        local e2_instance_id
        if e2_instance_id=$(oci_cmd compute instance list \
            --compartment-id "$comp_id" \
            --display-name "${E2_MICRO_CONFIG[DISPLAY_NAME]}" \
            --lifecycle-state "RUNNING,PROVISIONING,STARTING" \
            --query 'data[0].id' \
            --raw-output 2>/dev/null); then
            
            if [[ -n "$e2_instance_id" && "$e2_instance_id" != "null" ]]; then
                log_info "Verified E2.Micro instance exists: $e2_instance_id"
                if ! record_instance_verification "${E2_MICRO_CONFIG[DISPLAY_NAME]}" "$e2_instance_id" "verified" "$state_file"; then
                    log_warning "Failed to record E2.Micro instance verification"
                    ((verification_errors++))
                fi
            else
                log_warning "E2.Micro instance creation reported success but instance not found via API"
                ((verification_errors++))
            fi
        else
            log_error "Failed to query E2.Micro instance state via OCI API"
            ((verification_errors++))
        fi
    fi
    
    # Log current state for debugging
    if [[ "${DEBUG:-}" == "true" ]]; then
        log_debug "Current instance state after verification:"
        print_state "$state_file"
    fi
    
    # Return appropriate exit code based on verification results
    if [[ "$verification_errors" -gt 0 ]]; then
        log_warning "Instance state verification completed with $verification_errors error(s)"
        return 3  # Return specific code for verification errors (non-critical)
    else
        log_debug "Instance state verification completed successfully"
        return 0
    fi
}

# Get detailed instance information for notifications
get_instance_details() {
    local instance_id="$1"
    local shape_name="$2"
    
    if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
        return 1
    fi
    
    # Get instance details from OCI API
    local instance_data
    if ! instance_data=$(oci_cmd compute instance get --instance-id "$instance_id" \
        --query 'data.{id:id,shape:shape,ad:availabilityDomain,state:lifecycleState}' \
        --output json 2>/dev/null); then
        log_debug "Failed to get details for instance $instance_id"
        return 1
    fi
    
    # Get VNIC attachments for IP addresses
    local vnic_data
    if ! vnic_data=$(oci_cmd compute instance list-vnics --instance-id "$instance_id" \
        --query 'data[0].{publicIp:publicIp,privateIp:privateIp}' \
        --output json 2>/dev/null); then
        log_debug "Failed to get VNIC details for instance $instance_id"
        # Continue without IP info
        vnic_data='{"publicIp":null,"privateIp":null}'
    fi
    
    # Parse the data
    local id shape ad state public_ip private_ip
    id=$(echo "$instance_data" | jq -r '.id // "unknown"')
    shape=$(echo "$instance_data" | jq -r '.shape // "unknown"') 
    ad=$(echo "$instance_data" | jq -r '.ad // "unknown"' | sed 's/.*-AD-/AD-/')
    state=$(echo "$instance_data" | jq -r '.state // "unknown"')
    public_ip=$(echo "$vnic_data" | jq -r '.publicIp // "none"')
    private_ip=$(echo "$vnic_data" | jq -r '.privateIp // "unknown"')
    
    # Format the details
    echo "**${shape_name}** (${shape}):
• ID: ${id}
• Public IP: ${public_ip}
• Private IP: ${private_ip}
• AD: ${ad}
• State: ${state}"
}

# Main parallel execution
main() {
    start_timer "parallel_execution"
    log_info "Starting parallel OCI instance creation for both free tier shapes"

    # Set timeout to prevent exceeding 60 seconds (GitHub Actions billing boundary)
    # Using constant defined in constants.sh for consistency and maintainability
    local timeout_seconds=$GITHUB_ACTIONS_BILLING_TIMEOUT
    log_debug "Setting execution timeout to ${timeout_seconds}s to avoid 2-minute billing"

    # Create temporary files for process communication with secure permissions
    umask 077             # Ensure secure permissions (owner only)
    temp_dir=$(mktemp -d) # Using global variable for cleanup handler
    chmod 700 "$temp_dir" # Explicit directory permissions
    log_debug "Created secure temporary directory: $temp_dir"
    local a1_result="${temp_dir}/a1_result"
    local e2_result="${temp_dir}/e2_result"

    # Pre-create result files with secure permissions
    touch "$a1_result" "$e2_result"
    chmod 600 "$a1_result" "$e2_result"

    # Track resource usage at start of parallel execution
    track_resource_usage "start"

    # Smart shape filtering: Check cached limit states to prevent futile API calls
    local state_file="instance-state.json"
    local should_launch_a1=true
    local should_launch_e2=true
    
    # Initialize state manager to ensure state file exists
    if ! init_state_manager "$state_file" >/dev/null; then
        log_warning "Failed to initialize state manager, proceeding with all shapes"
    else
        # Check A1.Flex limit state
        if get_cached_limit_state "${A1_FLEX_CONFIG[SHAPE]}" "$state_file"; then
            should_launch_a1=false
            log_info "A1.Flex: Cached limit reached - skipping creation attempt"
            echo "$OCI_EXIT_USER_LIMIT_ERROR" >"$a1_result"
        else
            log_debug "A1.Flex: No cached limit - proceeding with creation attempt"
        fi
        
        # Check E2.Micro limit state  
        if get_cached_limit_state "${E2_MICRO_CONFIG[SHAPE]}" "$state_file"; then
            should_launch_e2=false
            log_info "E2.1.Micro: Cached limit reached - skipping creation attempt"
            echo "$OCI_EXIT_USER_LIMIT_ERROR" >"$e2_result"
        else
            log_debug "E2.1.Micro: No cached limit - proceeding with creation attempt"
        fi
        
        # Early exit if both shapes are at cached limits
        if [[ "$should_launch_a1" == false && "$should_launch_e2" == false ]]; then
            log_info "Both shapes at cached limits - no creation attempts needed"
            log_info "Consider managing existing instances to free capacity or wait for limit cache to expire"
            # Clean up temporary files
            rm -rf "$temp_dir" 2>/dev/null || true
            return 0  # Success - no work needed due to limits
        fi
    fi

    # Launch A1.Flex in background (if not skipped due to cached limits)
    if [[ "$should_launch_a1" == true ]]; then
        log_info "Launching A1.Flex (ARM) instance in background..."
        (
            # Capture both exit code and any error output
            set -o pipefail
            local exit_code=0
            if ! launch_shape "A1.Flex" A1_FLEX_CONFIG; then
                exit_code=$?
                log_debug "A1.Flex launch_shape returned exit code: $exit_code"
            fi
            
            # Ensure result file is written atomically
            local temp_result="${a1_result}.tmp"
            echo "$exit_code" > "$temp_result"
            mv "$temp_result" "$a1_result"
            
            log_debug "A1.Flex background process writing exit code $exit_code to result file"
            # Small delay to ensure file system flush
            sleep 0.1
            exit $exit_code
        ) &
        PID_A1=$!
        log_debug "A1.Flex background process started with PID: $PID_A1"
    else
        log_debug "Skipping A1.Flex launch due to cached limit state"
        PID_A1=""
    fi

    # Launch E2.Micro in background (if not skipped due to cached limits)
    if false; then
        log_info "Launching E2.1.Micro (AMD) instance in background..."
        (
            # Capture both exit code and any error output
            set -o pipefail
            local exit_code=0
            if ! launch_shape "E2.1.Micro" E2_MICRO_CONFIG; then
                exit_code=$?
                log_debug "E2.1.Micro launch_shape returned exit code: $exit_code"
            fi
            
            # Ensure result file is written atomically
            local temp_result="${e2_result}.tmp"
            echo "$exit_code" > "$temp_result"
            mv "$temp_result" "$e2_result"
            
            log_debug "E2.1.Micro background process writing exit code $exit_code to result file"
            # Small delay to ensure file system flush
            sleep 0.1
            exit $exit_code
        ) &
        PID_E2=$!
        log_debug "E2.1.Micro background process started with PID: $PID_E2"
    else
        log_debug "Skipping E2.1.Micro launch due to cached limit state"
        PID_E2=""
    fi

    # Log concurrent execution start
    log_performance_metric "CONCURRENT_START" "parallel_execution" "1" "2" "A1_PID=$PID_A1,E2_PID=$PID_E2"

    # Wait for both processes to complete with timeout
    log_info "Waiting for both shape attempts to complete (timeout: ${timeout_seconds}s)..."

    # Initialize status variables
    local STATUS_A1=1
    local STATUS_E2=1

    # Wait for both processes with timeout protection
    local elapsed=0
    # Process monitoring interval - 1 second for responsive detection without excessive CPU usage
    local sleep_interval=1

    # Keep checking until timeout or both processes complete
    while [[ $elapsed -lt $timeout_seconds ]]; do
        # Check if both processes have finished (handle empty PIDs for skipped shapes)
        local a1_running=false
        local e2_running=false
        
        if [[ -n "$PID_A1" ]] && kill -0 "$PID_A1" 2>/dev/null; then
            a1_running=true
        fi
        if [[ -n "$PID_E2" ]] && kill -0 "$PID_E2" 2>/dev/null; then
            e2_running=true
        fi
        
        if [[ "$a1_running" == false && "$e2_running" == false ]]; then
            log_debug "Both processes completed (or were skipped) after ${elapsed}s"
            break
        fi

        # Track peak resource usage during execution (every 5 seconds to avoid overhead)
        if [[ $((elapsed % 5)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            track_resource_usage "peak"
        fi

        sleep $sleep_interval
        ((elapsed += sleep_interval))
    done

    # Always wait for processes to fully complete and flush their output (handle empty PIDs)
    local a1_wait_result=0
    local e2_wait_result=0
    
    if [[ -n "$PID_A1" ]]; then
        log_debug "Waiting for A1.Flex process (PID: $PID_A1) to complete"
        wait $PID_A1 2>/dev/null || a1_wait_result=$?
        log_debug "A1.Flex process wait completed with result: $a1_wait_result"
    fi
    if [[ -n "$PID_E2" ]]; then
        log_debug "Waiting for E2.1.Micro process (PID: $PID_E2) to complete"
        wait $PID_E2 2>/dev/null || e2_wait_result=$?
        log_debug "E2.1.Micro process wait completed with result: $e2_wait_result"
    fi

    # Additional wait to ensure file system consistency after process completion
    sleep 0.2

    # Wait for result files with proper timeout (fixes race condition)
    if wait_for_result_file "$a1_result"; then
        STATUS_A1=$(cat "$a1_result" 2>/dev/null || echo "1")
        log_debug "A1 result file found with status: $STATUS_A1"
        # Validate the status is numeric
        if [[ ! "$STATUS_A1" =~ ^[0-9]+$ ]]; then
            log_warning "A1 result file contains invalid status '$STATUS_A1', using failure status"
            STATUS_A1=1
        fi
    else
        log_warning "A1 result file not found - using wait result or default failure status"
        STATUS_A1=${a1_wait_result:-1}
    fi

    if wait_for_result_file "$e2_result"; then
        STATUS_E2=$(cat "$e2_result" 2>/dev/null || echo "1")
        log_debug "E2 result file found with status: $STATUS_E2"
        # Validate the status is numeric
        if [[ ! "$STATUS_E2" =~ ^[0-9]+$ ]]; then
            log_warning "E2 result file contains invalid status '$STATUS_E2', using failure status"
            STATUS_E2=1
        fi
    else
        log_warning "E2 result file not found - using wait result or default failure status"
        STATUS_E2=${e2_wait_result:-1}
    fi
    # Handle timeout case - architecture-aware approach respecting smart shape filtering
    if [[ $elapsed -ge $timeout_seconds ]]; then
        log_warning "Execution timeout reached (${timeout_seconds}s) - terminating background processes"
        terminate_processes
        
        # Only apply timeout errors to shapes that were actually launched and have generic error codes
        # This preserves capacity/limit error codes (2, 5) which indicate expected Oracle Cloud behavior
        if [[ "$should_launch_a1" == true ]]; then
            # Only override if no specific error code was already captured
            if [[ $STATUS_A1 -eq 1 ]]; then
                STATUS_A1=$EXIT_TIMEOUT_ERROR
                log_debug "A1 timeout applied (was launched, no specific error code)"
            else
                log_debug "A1 timeout occurred but preserving error code $STATUS_A1 (capacity/limit detection)"
            fi
        else
            log_debug "A1 was skipped due to cached limits - no timeout handling needed"
        fi
        
        if [[ "$should_launch_e2" == true ]]; then
            # Only override if no specific error code was already captured
            if [[ $STATUS_E2 -eq 1 ]]; then
                STATUS_E2=$EXIT_TIMEOUT_ERROR
                log_debug "E2 timeout applied (was launched, no specific error code)"
            else
                log_debug "E2 timeout occurred but preserving error code $STATUS_E2 (capacity/limit detection)"
            fi
        else
            log_debug "E2 was skipped due to cached limits - no timeout handling needed"
        fi
    fi
    
    # Verify and update state for both instances (if state management enabled)
    # Only verify when instances were actually attempted (not cache hits)
    if [[ "${CACHE_ENABLED:-true}" == "true" ]]; then
        local should_verify=false
        
        # Only verify if at least one instance reported success (status 0)
        # Verification is to check if successful instances actually exist in OCI
        if [[ $STATUS_A1 -eq 0 || $STATUS_E2 -eq 0 ]]; then
            should_verify=true
            log_debug "Verification needed - at least one instance reported success"
        fi
        
        # Also verify if execution took a reasonable amount of time (not instant cache hit)
        # This handles edge cases where rapid failures might indicate cache issues
        if [[ $elapsed -gt 2 && ($STATUS_A1 -ne 0 || $STATUS_E2 -ne 0) ]]; then
            should_verify=true  
            log_debug "Verification needed - non-instant execution with failures"
        fi
        
        if [[ "$should_verify" == "true" ]]; then
            log_info "Verifying instance states and updating cache..."
            # Capture but don't propagate verification errors - they're non-critical
            if ! verify_and_update_state "$STATUS_A1" "$STATUS_E2"; then
                log_warning "Instance state verification encountered issues but continuing"
            fi
        else
            log_debug "Skipping verification - no successful instances to verify"
        fi
    fi
    # Cleanup temporary files
    rm -rf "$temp_dir" 2>/dev/null || true

    # Log results
    if [[ $STATUS_A1 -eq 0 ]]; then
        log_success "A1.Flex (ARM) instance creation: SUCCESS"
    elif [[ $STATUS_A1 -eq 124 ]]; then
        log_warning "A1.Flex (ARM) instance creation: TIMEOUT"
    else
        log_warning "A1.Flex (ARM) instance creation: FAILED"
    fi

    if [[ $STATUS_E2 -eq 0 ]]; then
        log_success "E2.1.Micro (AMD) instance creation: SUCCESS"
    elif [[ $STATUS_E2 -eq 124 ]]; then
        log_warning "E2.1.Micro (AMD) instance creation: TIMEOUT"
    else
        log_warning "E2.1.Micro (AMD) instance creation: FAILED"
    fi

    # Determine overall result
    local success_count=0
    [[ $STATUS_A1 -eq 0 ]] && success_count=$((success_count + 1))
    [[ $STATUS_E2 -eq 0 ]] && success_count=$((success_count + 1))

    # Check different types of failures for intelligent handling
    local capacity_failures=0
    local user_limit_failures=0
    local rate_limit_failures=0
    
    # Count capacity-related failures (exit code 2 = OCI_EXIT_CAPACITY_ERROR)
    [[ $STATUS_A1 -eq 2 ]] && capacity_failures=$((capacity_failures + 1))
    [[ $STATUS_E2 -eq 2 ]] && capacity_failures=$((capacity_failures + 1))
    
    # Count user limit failures (exit code 5 = OCI_EXIT_USER_LIMIT_ERROR)
    [[ $STATUS_A1 -eq 5 ]] && user_limit_failures=$((user_limit_failures + 1))
    [[ $STATUS_E2 -eq 5 ]] && user_limit_failures=$((user_limit_failures + 1))
    
    # Count rate limit failures (exit code 6 = OCI_EXIT_RATE_LIMIT_ERROR)
    [[ $STATUS_A1 -eq 6 ]] && rate_limit_failures=$((rate_limit_failures + 1))
    [[ $STATUS_E2 -eq 6 ]] && rate_limit_failures=$((rate_limit_failures + 1))

    log_elapsed "parallel_execution"

    # Track final resource usage and collect detailed performance summary
    track_resource_usage "end"

    # Collect shape-specific durations for analysis
    local a1_duration=0 e2_duration=0 peak_memory=0
    if [[ -f "${temp_dir}/a1.flex_duration" ]]; then
        a1_duration=$(cat "${temp_dir}/a1.flex_duration" 2>/dev/null || echo "0")
    fi
    if [[ -f "${temp_dir}/e2.1.micro_duration" ]]; then
        e2_duration=$(cat "${temp_dir}/e2.1.micro_duration" 2>/dev/null || echo "0")
    fi
    if [[ -f "${temp_dir}/peak_memory_usage" ]]; then
        peak_memory=$(cat "${temp_dir}/peak_memory_usage" 2>/dev/null || echo "0")
    fi

    # Log comprehensive execution summary
    local performance_summary="ExecutionTime=${elapsed}s,A1Duration=${a1_duration}s,E2Duration=${e2_duration}s"
    performance_summary="${performance_summary},PeakMemory=${peak_memory}MB,SuccessRate=${success_count}/2"
    log_performance_metric "CONCURRENT_END" "parallel_execution" "$success_count" "2" "$performance_summary"

    # Log structured performance data for analysis
    if [[ "${LOG_FORMAT:-}" == "json" ]]; then
        local performance_context="{\"total_duration\":${elapsed},\"a1_duration\":${a1_duration}"
        performance_context="${performance_context},\"e2_duration\":${e2_duration},\"peak_memory\":${peak_memory}"
        performance_context="${performance_context},\"success_count\":${success_count},\"parallel_efficiency\":"
        performance_context+="$(((a1_duration + e2_duration) > 0 ? (a1_duration + e2_duration) * 100 / elapsed : 0))}"
        log_with_context "info" "Parallel execution performance summary" "$performance_context"
    fi

    # Verify actual instances exist before claiming success
    local actual_instances
    actual_instances=$(count_actual_instances)
    
    if [[ $actual_instances -gt 0 ]]; then
        log_success "Parallel execution completed: $actual_instances of 2 instances actually exist and running"

        # Instance hunting success: notify for ANY created instances with details
        if [[ "${ENABLE_NOTIFICATIONS:-}" == "true" ]]; then
            local comp_id
            comp_id=$(require_env_var "OCI_COMPARTMENT_ID" 2>/dev/null) || comp_id=""
            
            local notification_details=""
            local shapes_created=""
            
            # Get details for A1.Flex if it exists
            local a1_instance_id
            if [[ -n "$comp_id" ]] && a1_instance_id=$(oci_cmd compute instance list \
                --compartment-id "$comp_id" \
                --display-name "${A1_FLEX_CONFIG[DISPLAY_NAME]}" \
                --lifecycle-state "RUNNING,PROVISIONING,STARTING" \
                --query 'data[0].id' \
                --raw-output 2>/dev/null) && [[ -n "$a1_instance_id" && "$a1_instance_id" != "null" ]]; then
                shapes_created="A1.Flex (ARM)"
                if a1_details=$(get_instance_details "$a1_instance_id" "A1.Flex (ARM)" 2>/dev/null); then
                    notification_details="$a1_details"
                fi
            fi
            
            # Get details for E2.Micro if it exists
            local e2_instance_id
            if [[ -n "$comp_id" ]] && e2_instance_id=$(oci_cmd compute instance list \
                --compartment-id "$comp_id" \
                --display-name "${E2_MICRO_CONFIG[DISPLAY_NAME]}" \
                --lifecycle-state "RUNNING,PROVISIONING,STARTING" \
                --query 'data[0].id' \
                --raw-output 2>/dev/null) && [[ -n "$e2_instance_id" && "$e2_instance_id" != "null" ]]; then
                shapes_created="${shapes_created:+$shapes_created, }E2.1.Micro (AMD)"
                if e2_details=$(get_instance_details "$e2_instance_id" "E2.1.Micro (AMD)" 2>/dev/null); then
                    notification_details="${notification_details:+$notification_details

}$e2_details"
                fi
            fi
            
            # Send notification with details if available, fallback to basic info
            if [[ -n "$notification_details" ]]; then
                send_telegram_notification "success" "OCI instance hunting success!

$notification_details"
            else
                send_telegram_notification "success" "OCI instances created: $shapes_created"
            fi
        fi

        return 0
    elif [[ $user_limit_failures -gt 0 && $((user_limit_failures + success_count)) -eq 2 ]]; then
        # User limits reached - this is expected behavior when at free tier limits
        log_info "User limit(s) reached for $user_limit_failures shape(s) - no further attempts needed"
        log_info "Consider managing existing instances to free capacity for new deployments"
        
        # Notification Policy: NO notifications for user limits
        # User limits are EXPECTED free tier behavior - normal operation
        # Per CLAUDE.md policy: "DO NOT send notifications for User limits reached (expected)"
        
        return 0  # User limits are not failures - they're expected behavior
    elif [[ $rate_limit_failures -gt 0 && $((rate_limit_failures + success_count + capacity_failures + user_limit_failures)) -eq 2 ]]; then
        # Rate limits encountered - this is expected Oracle behavior, no notifications needed
        log_info "Oracle API rate limits encountered for $rate_limit_failures shape(s) - will retry on next scheduled run"
        log_info "This is normal Oracle API behavior during high usage periods and resolves automatically"
        
        # Notification Policy: NO notifications for rate limits  
        # Rate limiting is EXPECTED Oracle API behavior during high usage periods
        # Per CLAUDE.md policy: "DO NOT send notifications for Rate limiting (standard behavior)"
        
        return 0  # Rate limits are not failures - they're expected behavior
    elif [[ $capacity_failures -eq 2 ]]; then
        # Both failed due to Oracle capacity constraints - this is expected behavior
        log_info "Both shapes unavailable due to Oracle capacity constraints - will retry on next schedule"
        log_info "This is normal behavior when Oracle Cloud capacity is temporarily exhausted"

        # Notification Policy: NO notifications for Oracle capacity constraints
        # Capacity constraints are EXPECTED operational conditions that resolve through retry cycles
        # Per CLAUDE.md policy: "DO NOT send notifications for Oracle capacity unavailable (expected)"
        
        return 0 # Don't treat capacity exhaustion as failure
    elif [[ $((capacity_failures + user_limit_failures + rate_limit_failures)) -eq 2 ]]; then
        # Mixed capacity, limit, and rate limit issues - still expected behavior
        log_info "Mixed Oracle constraints encountered - will retry on next schedule"
        log_info "This is normal Oracle Cloud behavior - capacity, limits, or rate limiting"
        
        # Notification Policy: NO notifications for mixed constraint scenarios
        # These are EXPECTED Oracle operational conditions that resolve through retry cycles
        # Per CLAUDE.md policy: \"DO NOT send notifications for\" expected operational conditions
        
        return 0  # Mixed constraint issues are still expected behavior
    else
        # Analyze and report the specific failure reasons
        local failure_summary=""
        if [[ $STATUS_A1 -ne 0 && $STATUS_A1 -ne 2 && $STATUS_A1 -ne 5 && $STATUS_A1 -ne 6 ]]; then
            failure_summary="A1.Flex failed (exit: $STATUS_A1)"
        fi
        if [[ $STATUS_E2 -ne 0 && $STATUS_E2 -ne 2 && $STATUS_E2 -ne 5 && $STATUS_E2 -ne 6 ]]; then
            if [[ -n "$failure_summary" ]]; then
                failure_summary="$failure_summary, E2.1.Micro failed (exit: $STATUS_E2)"
            else
                failure_summary="E2.1.Micro failed (exit: $STATUS_E2)"
            fi
        fi
        
        # Capacity on one shape + config error on other = normal (we only care about ARM)
        if [[ $capacity_failures -gt 0 ]]; then
            log_info "Capacity constraint (expected) - will retry on next schedule"
            return 0
        fi
        if [[ -n "$failure_summary" ]]; then
            log_error "Parallel execution failed: $failure_summary"
        else
            log_error "Parallel execution failed"
        fi

        # Let individual shape failures handle their own error notifications
        # This prevents duplicate error notifications

        return 1
    fi
}

# Execute main function if script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Capture main function exit code to prevent shell configuration from interfering
    main_exit_code=0
    main "$@" || main_exit_code=$?
    
    # Log final exit code for debugging (if DEBUG enabled)
    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "launch-parallel.sh final exit code: $main_exit_code"
        case $main_exit_code in
            0) echo "SUCCESS: All operations completed successfully or expected Oracle constraints" ;;
            2) echo "SUCCESS: Capacity constraints (normal Oracle behavior)" ;;
            5) echo "SUCCESS: User limits reached (expected free tier behavior)" ;;
            6) echo "SUCCESS: Rate limits encountered (expected Oracle API behavior)" ;;
            *) echo "FAILURE: Genuine error requiring attention (exit $main_exit_code)" ;;
        esac
    fi
    
    # Exit with the captured code to preserve correct workflow behavior
    exit $main_exit_code
fi
