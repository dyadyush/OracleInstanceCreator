#!/bin/bash

# Parallel OCI instance launcher script
# Attempts to create both free tier shapes simultaneously:
# - VM.Standard.A1.Flex (ARM): 2 OCPUs, 12GB RAM (BIG)
# - VM.Standard.A1.Flex (ARM): 1 OCPU, 6GB RAM (SMALL fallback)
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
        free -m | awk 'NR==2{printf "%.1f", $3}'
    elif command -v vm_stat >/dev/null 2>&1; then
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
    local phase="$1"
    local memory_usage
    memory_usage=$(get_memory_usage)
    log_performance_metric "RESOURCE_USAGE" "parallel_execution" "$phase" "1" "Memory=${memory_usage}MB"
    if [[ "$phase" == "peak" ]]; then
        echo "$memory_usage" >"${temp_dir}/peak_memory_usage" 2>/dev/null || true
    fi
}

# Terminate background processes gracefully then forcefully
terminate_processes() {
    if [[ -n "$PID_A1" ]] && kill -0 "$PID_A1" 2>/dev/null; then
        log_debug "Terminating A1 process (PID: $PID_A1)"
        kill "$PID_A1" 2>/dev/null || true
    fi
    if [[ -n "$PID_E2" ]] && kill -0 "$PID_E2" 2>/dev/null; then
        log_debug "Terminating E2 process (PID: $PID_E2)"
        kill "$PID_E2" 2>/dev/null || true
    fi
    sleep "$GRACEFUL_TERMINATION_DELAY"

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
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir" 2>/dev/null || true
    fi
    log_info "Cleanup completed"
    exit "$OCI_EXIT_GENERAL_ERROR"
}

trap cleanup_handler SIGTERM SIGINT

# ============================================================================
# Shape configurations for Oracle Cloud free tier
# BIG: 2 OCPU / 12 GB — максимальный бесплатный ARM
# SMALL: 1 OCPU / 6 GB — половина, ловится в разы легче
# ============================================================================

# shellcheck disable=SC2034
declare -A A1_FLEX_CONFIG=(
    ["SHAPE"]="VM.Standard.A1.Flex"
    ["OCPUS"]="2"
    ["MEMORY_IN_GBS"]="12"
    ["DISPLAY_NAME"]="a1-flex-sg"
)

# shellcheck disable=SC2034
declare -A A1_FLEX_SMALL_CONFIG=(
    ["SHAPE"]="VM.Standard.A1.Flex"
    ["OCPUS"]="1"
    ["MEMORY_IN_GBS"]="6"
    ["DISPLAY_NAME"]="a1-flex-sg"
)

# shellcheck disable=SC2034
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
    
    local a1_instance_id
    if a1_instance_id=$(oci_cmd compute instance list \
        --compartment-id "$comp_id" \
        --display-name "${A1_FLEX_CONFIG[DISPLAY_NAME]}" \
        --lifecycle-state "RUNNING,PROVISIONING,STARTING" \
        --query 'data[0].id' \
        --raw-output 2>&1) && [[ -n "$a1_instance_id" && "$a1_instance_id" != "null" ]]; then
        ((actual_count++)) || true
    else
        if [[ -n "$a1_instance_id" && "$a1_instance_id" =~ (ERROR|ServiceError|Authentication) ]]; then
            log_debug "A1.Flex instance verification failed: ${a1_instance_id:0:100}..."
        fi
    fi
    
    local e2_instance_id
    if e2_instance_id=$(oci_cmd compute instance list \
        --compartment-id "$comp_id" \
        --display-name "${E2_MICRO_CONFIG[DISPLAY_NAME]}" \
        --lifecycle-state "RUNNING,PROVISIONING,STARTING" \
        --query 'data[0].id' \
        --raw-output 2>&1) && [[ -n "$e2_instance_id" && "$e2_instance_id" != "null" ]]; then
        ((actual_count++)) || true
    else
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

    local shape_start_time
    shape_start_time=$(date +%s)

    export OCI_SHAPE="${config[SHAPE]}"
    export OCI_OCPUS="${config[OCPUS]}"
    export OCI_MEMORY_IN_GBS="${config[MEMORY_IN_GBS]}"
    export INSTANCE_DISPLAY_NAME="${config[DISPLAY_NAME]}"

    local script_dir
    script_dir="$(dirname "$0")"
    "$script_dir/launch-instance.sh"
    local exit_code=$?

    local shape_end_time duration
    shape_end_time=$(date +%s)
    duration=$((shape_end_time - shape_start_time))

    log_performance_metric "SHAPE_DURATION" "$shape_name" "$duration" "$exit_code" "Shape=${config[SHAPE]}"

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
    
    if ! init_state_manager "$state_file" >/dev/null; then
        log_error "Failed to initialize state manager"
        return 1
    fi
    
    local comp_id
    if ! comp_id=$(require_env_var "OCI_COMPARTMENT_ID" 2>/dev/null); then
        log_error "OCI_COMPARTMENT_ID not available - cannot verify instance state"
        return 2
    fi
    
    if [[ "$status_a1" -eq 0 ]]; then
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
                    ((verification_errors++)) || true
                fi
            else
                log_warning "A1.Flex instance creation reported success but instance not found via API"
                ((verification_errors++)) || true
            fi
        else
            log_error "Failed to query A1.Flex instance state via OCI API"
            ((verification_errors++)) || true
        fi
    fi
    
    if [[ "$status_e2" -eq 0 ]]; then
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
                    ((verification_errors++)) || true
                fi
            else
                log_warning "E2.Micro instance creation reported success but instance not found via API"
                ((verification_errors++)) || true
            fi
        else
            log_error "Failed to query E2.Micro instance state via OCI API"
            ((verification_errors++)) || true
        fi
    fi
    
    if [[ "${DEBUG:-}" == "true" ]]; then
        log_debug "Current instance state after verification:"
        print_state "$state_file"
    fi
    
    if [[ "$verification_errors" -gt 0 ]]; then
        log_warning "Instance state verification completed with $verification_errors error(s)"
        return 3
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
    
    local instance_data
    if ! instance_data=$(oci_cmd compute instance get --instance-id "$instance_id" \
        --query 'data.{id:id,shape:shape,ad:availabilityDomain,state:lifecycleState}' \
        --output json 2>/dev/null); then
        log_debug "Failed to get details for instance $instance_id"
        return 1
    fi
    
    local vnic_data
    if ! vnic_data=$(oci_cmd compute instance list-vnics --instance-id "$instance_id" \
        --query 'data[0].{publicIp:publicIp,privateIp:privateIp}' \
        --output json 2>/dev/null); then
        log_debug "Failed to get VNIC details for instance $instance_id"
        vnic_data='{"publicIp":null,"privateIp":null}'
    fi
    
    local id shape ad state public_ip private_ip
    id=$(echo "$instance_data" | jq -r '.id // "unknown"')
    shape=$(echo "$instance_data" | jq -r '.shape // "unknown"') 
    ad=$(echo "$instance_data" | jq -r '.ad // "unknown"' | sed 's/.*-AD-/AD-/')
    state=$(echo "$instance_data" | jq -r '.state // "unknown"')
    public_ip=$(echo "$vnic_data" | jq -r '.publicIp // "none"')
    private_ip=$(echo "$vnic_data" | jq -r '.privateIp // "unknown"')
    
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

    local timeout_seconds=$GITHUB_ACTIONS_BILLING_TIMEOUT
    log_debug "Setting execution timeout to ${timeout_seconds}s to avoid 2-minute billing"

    umask 077
    temp_dir=$(mktemp -d)
    chmod 700 "$temp_dir"
    log_debug "Created secure temporary directory: $temp_dir"
    local a1_result="${temp_dir}/a1_result"
    local e2_result="${temp_dir}/e2_result"

    # Pre-create result files with secure permissions
    touch "$a1_result"
    echo "5" >"$e2_result"   # 5 = user limit — E2 не нужен
    chmod 600 "$a1_result" "$e2_result"

    track_resource_usage "start"

    local state_file="instance-state.json"
    local should_launch_a1=true
    local should_launch_e2=true
    
    if ! init_state_manager "$state_file" >/dev/null; then
        log_warning "Failed to initialize state manager, proceeding with all shapes"
    else
        if get_cached_limit_state "${A1_FLEX_CONFIG[SHAPE]}" "$state_file"; then
            should_launch_a1=false
            log_info "A1.Flex: Cached limit reached - skipping creation attempt"
            echo "$OCI_EXIT_USER_LIMIT_ERROR" >"$a1_result"
        else
            log_debug "A1.Flex: No cached limit - proceeding with creation attempt"
        fi
        
        if get_cached_limit_state "${E2_MICRO_CONFIG[SHAPE]}" "$state_file"; then
            should_launch_e2=false
            log_info "E2.1.Micro: Cached limit reached - skipping creation attempt"
            echo "$OCI_EXIT_USER_LIMIT_ERROR" >"$e2_result"
        else
            log_debug "E2.1.Micro: No cached limit - proceeding with creation attempt"
        fi
        
        if [[ "$should_launch_a1" == false && "$should_launch_e2" == false ]]; then
            log_info "Both shapes at cached limits - no creation attempts needed"
            rm -rf "$temp_dir" 2>/dev/null || true
            return 0
        fi
    fi

    # ========================================================================
    # Launch A1.Flex with alternating BIG/SMALL configs
    # ========================================================================
    if [[ "$should_launch_a1" == true ]]; then
        log_info "Launching A1.Flex (ARM) instance in background..."
        (
            set -o pipefail
            local exit_code=0
            local max_cycles="${INTERNAL_CYCLES:-4}"
            local cycle_wait="${INTERNAL_CYCLE_WAIT:-30}"
            local big_cycles=$(( max_cycles / 2 ))
            [[ $big_cycles -lt 1 ]] && big_cycles=1

            for ((cycle=1; cycle<=max_cycles; cycle++)); do
                local cycle_config
                local cycle_label
                local cycle_ocpus
                local cycle_mem
                if [[ $cycle -le $big_cycles ]]; then
                    cycle_config="A1_FLEX_CONFIG"
                    cycle_label="BIG 2/12"
                else
                    cycle_config="A1_FLEX_SMALL_CONFIG"
                    cycle_label="SMALL 1/6"
                fi

                log_info "=== A1.Flex [$cycle_label] internal cycle $cycle/$max_cycles ==="

                if ! launch_shape "A1.Flex" "$cycle_config"; then
                    exit_code=$?
                else
                    exit_code=0
                fi
                log_debug "A1.Flex cycle $cycle ($cycle_label) returned exit code: $exit_code"

                # Проверяем, не создался ли инстанс
                local comp_id_check
                comp_id_check=$(require_env_var "OCI_COMPARTMENT_ID" 2>/dev/null) || comp_id_check=""
                if [[ -n "$comp_id_check" ]]; then
                    local found_id
                    found_id=$(oci_cmd compute instance list \
                        --compartment-id "$comp_id_check" \
                        --display-name "${A1_FLEX_CONFIG[DISPLAY_NAME]}" \
                        --lifecycle-state "RUNNING,PROVISIONING" \
                        --query 'data[0].id' \
                        --raw-output 2>/dev/null || echo "")
                    if [[ -n "$found_id" && "$found_id" != "null" ]]; then
                        log_success "A1.Flex instance created after cycle $cycle ($cycle_label): $found_id"
                        exit_code=0
                        break
                    fi
                fi

                if [[ $cycle -lt $max_cycles ]]; then
                    log_info "Cycle $cycle ($cycle_label) complete - sleeping ${cycle_wait}s before cycle $((cycle+1))"
                    sleep "$cycle_wait"
                fi
            done

            local temp_result="${a1_result}.tmp"
            echo "$exit_code" > "$temp_result"
            mv "$temp_result" "$a1_result"

            log_debug "A1.Flex background process writing exit code $exit_code to result file"
            sleep 0.1
            exit $exit_code
        ) &
        PID_A1=$!
        log_debug "A1.Flex background process started with PID: $PID_A1"
    else
        log_debug "Skipping A1.Flex launch due to cached limit state"
        PID_A1=""
    fi

    log_performance_metric "CONCURRENT_START" "parallel_execution" "1" "2" "A1_PID=$PID_A1,E2_PID=$PID_E2"

    log_info "Waiting for both shape attempts to complete (timeout: ${timeout_seconds}s)..."

    local STATUS_A1=1
    local STATUS_E2=1

    local elapsed=0
    local sleep_interval=1

    while [[ $elapsed -lt $timeout_seconds ]]; do
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

        if [[ $((elapsed % 5)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            track_resource_usage "peak"
        fi

        sleep $sleep_interval
        ((elapsed += sleep_interval)) || true
    done

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

    sleep 0.2

    if wait_for_result_file "$a1_result"; then
        STATUS_A1=$(cat "$a1_result" 2>/dev/null || echo "1")
        log_debug "A1 result file found with status: $STATUS_A1"
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
        if [[ ! "$STATUS_E2" =~ ^[0-9]+$ ]]; then
            log_warning "E2 result file contains invalid status '$STATUS_E2', using failure status"
            STATUS_E2=1
        fi
    else
        log_warning "E2 result file not found - using wait result or default failure status"
        STATUS_E2=${e2_wait_result:-1}
    fi

    if [[ $elapsed -ge $timeout_seconds ]]; then
        log_warning "Execution timeout reached (${timeout_seconds}s) - terminating background processes"
        terminate_processes
        
        if [[ "$should_launch_a1" == true ]]; then
            if [[ $STATUS_A1 -eq 1 ]]; then
                STATUS_A1=$EXIT_TIMEOUT_ERROR
                log_debug "A1 timeout applied (was launched, no specific error code)"
            else
                log_debug "A1 timeout occurred but preserving error code $STATUS_A1 (capacity/limit detection)"
            fi
        fi
        
        if [[ "$should_launch_e2" == true ]]; then
            if [[ $STATUS_E2 -eq 1 ]]; then
                STATUS_E2=$EXIT_TIMEOUT_ERROR
                log_debug "E2 timeout applied (was launched, no specific error code)"
            else
                log_debug "E2 timeout occurred but preserving error code $STATUS_E2 (capacity/limit detection)"
            fi
        fi
    fi
    
    if [[ "${CACHE_ENABLED:-true}" == "true" ]]; then
        local should_verify=false
        
        if [[ $STATUS_A1 -eq 0 || $STATUS_E2 -eq 0 ]]; then
            should_verify=true
            log_debug "Verification needed - at least one instance reported success"
        fi
        
        if [[ $elapsed -gt 2 && ($STATUS_A1 -ne 0 || $STATUS_E2 -ne 0) ]]; then
            should_verify=true  
            log_debug "Verification needed - non-instant execution with failures"
        fi
        
        if [[ "$should_verify" == "true" ]]; then
            log_info "Verifying instance states and updating cache..."
            if ! verify_and_update_state "$STATUS_A1" "$STATUS_E2"; then
                log_warning "Instance state verification encountered issues but continuing"
            fi
        else
            log_debug "Skipping verification - no successful instances to verify"
        fi
    fi

    rm -rf "$temp_dir" 2>/dev/null || true

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

    local success_count=0
    [[ $STATUS_A1 -eq 0 ]] && success_count=$((success_count + 1)) || true
    [[ $STATUS_E2 -eq 0 ]] && success_count=$((success_count + 1)) || true

    local capacity_failures=0
    local user_limit_failures=0
    local rate_limit_failures=0
    
    [[ $STATUS_A1 -eq 2 ]] && capacity_failures=$((capacity_failures + 1)) || true
    [[ $STATUS_E2 -eq 2 ]] && capacity_failures=$((capacity_failures + 1)) || true
    
    [[ $STATUS_A1 -eq 5 ]] && user_limit_failures=$((user_limit_failures + 1)) || true
    [[ $STATUS_E2 -eq 5 ]] && user_limit_failures=$((user_limit_failures + 1)) || true
    
    [[ $STATUS_A1 -eq 6 ]] && rate_limit_failures=$((rate_limit_failures + 1)) || true
    [[ $STATUS_E2 -eq 6 ]] && rate_limit_failures=$((rate_limit_failures + 1)) || true

    log_elapsed "parallel_execution"
    track_resource_usage "end"

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

    local performance_summary="ExecutionTime=${elapsed}s,A1Duration=${a1_duration}s,E2Duration=${e2_duration}s"
    performance_summary="${performance_summary},PeakMemory=${peak_memory}MB,SuccessRate=${success_count}/2"
    log_performance_metric "CONCURRENT_END" "parallel_execution" "$success_count" "2" "$performance_summary"

    local actual_instances
    actual_instances=$(count_actual_instances)
    
    if [[ $actual_instances -gt 0 ]]; then
        log_success "Parallel execution completed: $actual_instances of 2 instances actually exist and running"

        if [[ "${ENABLE_NOTIFICATIONS:-}" == "true" ]]; then
            local comp_id
            comp_id=$(require_env_var "OCI_COMPARTMENT_ID" 2>/dev/null) || comp_id=""
            
            local notification_details=""
            local shapes_created=""
            
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
            
            if [[ -n "$notification_details" ]]; then
                send_telegram_notification "success" "OCI instance hunting success!

$notification_details"
            else
                send_telegram_notification "success" "OCI instances created: $shapes_created"
            fi
        fi

        return 0
    elif [[ $user_limit_failures -gt 0 && $((user_limit_failures + success_count)) -eq 2 ]]; then
        log_info "User limit(s) reached for $user_limit_failures shape(s) - no further attempts needed"
        log_info "Consider managing existing instances to free capacity for new deployments"
        return 0
    elif [[ $rate_limit_failures -gt 0 && $((rate_limit_failures + success_count + capacity_failures + user_limit_failures)) -eq 2 ]]; then
        log_info "Oracle API rate limits encountered for $rate_limit_failures shape(s) - will retry on next scheduled run"
        return 0
    elif [[ $capacity_failures -eq 2 ]]; then
        log_info "Both shapes unavailable due to Oracle capacity constraints - will retry on next schedule"
        return 0
    elif [[ $((capacity_failures + user_limit_failures + rate_limit_failures)) -eq 2 ]]; then
        log_info "Mixed Oracle constraints encountered - will retry on next schedule"
        return 0
    else
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
        
        if [[ $capacity_failures -gt 0 ]]; then
            log_info "Capacity constraint (expected) - will retry on next schedule"
            return 0
        fi
        if [[ -n "$failure_summary" ]]; then
            log_error "Parallel execution failed: $failure_summary"
        else
            log_error "Parallel execution failed"
        fi

        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_exit_code=0
    main "$@" || main_exit_code=$?
    
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
    
    exit $main_exit_code
fi
