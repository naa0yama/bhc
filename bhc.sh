#!/bin/bash
#
# Block Device Health Check Script (bhc.sh)
# HDD/SSD Acceptance Test Script
# - Seagate HDD counterfeit issue check
# - SMART initialization & failure statistics check
# - badblocks full sector write test
# - SMART short/long test execution
#

set -euo pipefail

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Log directory
readonly LOG_DIR="/var/log/bhc"
LOG_FILE=""

# Global variables
DEVICE=""
DEVICE_PATH=""
SMART_BEFORE=""
SMART_AFTER=""

#######################################
# Banner display
#######################################
show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║     Block Device Health Check (bhc.sh)                      ║
║                                                              ║
║     HDD/SSD Acceptance Test Script                          ║
║     - SMART Diagnostics (short/long test)                   ║
║     - badblocks Full Sector Write Test                      ║
║     - Counterfeit & Failure Statistics Check                ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

#######################################
# Log output functions
#######################################
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

log_command() {
    echo -e "${BLUE}[CMD]${NC} $*" | tee -a "${LOG_FILE}"
}

#######################################
# Check root privileges
#######################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        echo "Please run: sudo $0"
        exit 1
    fi
}

#######################################
# Check tmux execution
#######################################
check_tmux() {
    if [[ -z "${TMUX:-}" ]]; then
        echo -e "${RED}Error: This script must be run inside a tmux session${NC}"
        echo "Reason: Long-running tests require session protection from disconnection"
        echo ""
        echo "Start a tmux session with:"
        echo "  tmux new-session -s bhc"
        echo "  sudo $0"
        exit 1
    fi
}

#######################################
# Check required commands
#######################################
check_commands() {
    local required_commands=(
        "smartctl:smartmontools"
        "badblocks:e2fsprogs"
        "lsblk:util-linux"
        "blockdev:util-linux"
    )
    
    local missing_packages=()
    
    for cmd_pkg in "${required_commands[@]}"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        
        if ! command -v "${cmd}" &> /dev/null; then
            missing_packages+=("${pkg}")
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Required commands not found${NC}"
        echo ""
        echo "To install on Debian 13, run:"
        echo -e "${GREEN}sudo apt update${NC}"
        
        # Remove duplicates
        local -a unique_packages
        mapfile -t unique_packages < <(printf '%s\n' "${missing_packages[@]}" | sort -u)
        
        echo -e "${GREEN}sudo apt install -y ${unique_packages[*]}${NC}"
        exit 1
    fi
}

#######################################
# Device selection
#######################################
select_device() {
    echo ""
    echo -e "${CYAN}=== Available Block Devices ===${NC}"
    echo ""
    
    lsblk -o NAME,HCTL,MODEL,SERIAL | grep -E '^s' || {
        echo -e "${RED}Error: No block devices found${NC}"
        exit 1
    }
    
    echo ""
    echo -ne "${YELLOW}Enter device name to test (e.g., sda): ${NC}"
    read -r DEVICE
    
    DEVICE_PATH="/dev/${DEVICE}"
    
    if [[ ! -b "${DEVICE_PATH}" ]]; then
        echo -e "${RED}Error: ${DEVICE_PATH} is not a block device${NC}"
        exit 1
    fi
    
    # Check if device is mounted
    if mount | grep -q "^${DEVICE_PATH}"; then
        echo -e "${RED}Error: ${DEVICE_PATH} is currently mounted${NC}"
        echo "Please unmount it and run again"
        exit 1
    fi
}

#######################################
# Initialize log file and output all SMART data
#######################################
initialize_log() {
    local device_type
    local model
    local serial
    local timestamp
    
    # Get device type
    if smartctl -i "${DEVICE_PATH}" | grep -q "SATA"; then
        device_type="ata"
    elif smartctl -i "${DEVICE_PATH}" | grep -q "NVMe"; then
        device_type="nvme"
    else
        device_type="unknown"
    fi
    
    # Get model and serial number
    model=$(smartctl -i "${DEVICE_PATH}" | grep "Device Model:" | awk '{print $3}' | tr -d ' ' || echo "UNKNOWN")
    if [[ -z "${model}" ]] || [[ "${model}" == "UNKNOWN" ]]; then
        model=$(smartctl -i "${DEVICE_PATH}" | grep "Model Number:" | awk '{print $3}' | tr -d ' ' || echo "UNKNOWN")
    fi
    
    serial=$(smartctl -i "${DEVICE_PATH}" | grep "Serial Number:" | awk '{print $3}' | tr -d ' ' || echo "UNKNOWN")
    
    timestamp=$(date '+%Y%m%dT%H%M%S')
    
    # Create log directory
    mkdir -p "${LOG_DIR}"
    
    # Log file name
    LOG_FILE="${LOG_DIR}/${device_type}_${model}_${serial}_${timestamp}.log"
    
    log_info "=================================="
    log_info "Block Device Health Check Started"
    log_info "Device: ${DEVICE_PATH}"
    log_info "Type: ${device_type}"
    log_info "Model: ${model}"
    log_info "Serial: ${serial}"
    log_info "=================================="
    
    # Output all SMART information at the beginning
    log_info "Outputting complete SMART information..."
    {
        echo ""
        echo "=== Complete SMART Information (Initial) ==="
        smartctl -x "${DEVICE_PATH}" 2>&1
        echo ""
        echo "=== SMART All Attributes (Initial) ==="
        smartctl -A "${DEVICE_PATH}" 2>&1
        echo ""
        echo "=== SMART Capabilities ==="
        smartctl -c "${DEVICE_PATH}" 2>&1
        echo ""
        echo "=== SMART Self-test Log ==="
        smartctl -l selftest "${DEVICE_PATH}" 2>&1
        echo ""
        echo "=== SMART Error Log ==="
        smartctl -l error "${DEVICE_PATH}" 2>&1
        echo ""
    } >> "${LOG_FILE}"
}

#######################################
# Check Seagate firmware counterfeit issue
#######################################
check_seagate_firmware() {
    log_info "Checking for Seagate counterfeit firmware issue..."
    
    local model
    model=$(smartctl -i "${DEVICE_PATH}" | grep -i "model" | head -1)
    
    if echo "${model}" | grep -iq "seagate\|barracuda"; then
        log_warn "Seagate device detected"
        
        # Check firmware version
        local firmware
        firmware=$(smartctl -i "${DEVICE_PATH}" | grep "Firmware Version:" | awk '{print $3}')
        log_info "Firmware Version: ${firmware}"
        
        # Check capacity
        local capacity
        capacity=$(smartctl -i "${DEVICE_PATH}" | grep "User Capacity:" | grep -oP '\d+\s+(bytes|GB|TB)' | head -1)
        log_info "Capacity: ${capacity}"
        
        log_warn "If counterfeit is suspected, verify firmware on manufacturer's website"
    fi
}

#######################################
# Check SMART initial values
#######################################
check_smart_initial() {
    log_info "Checking SMART initial values..."
    
    # Check if SMART is enabled
    if ! smartctl -i "${DEVICE_PATH}" | grep -q "SMART support is: Enabled"; then
        log_warn "SMART is disabled. Attempting to enable..."
        smartctl -s on "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1 || true
    fi
    
    # Save all SMART information
    {
        echo "=== SMART Information (Before Test) ==="
        smartctl -x "${DEVICE_PATH}"
        echo ""
    } >> "${LOG_FILE}"
    
    SMART_BEFORE=$(smartctl -A "${DEVICE_PATH}" 2>&1)
    
    # Check critical failure statistics
    log_info "Failure Statistics Check:"
    
    local critical_attrs=(
        "1:Raw_Read_Error_Rate"
        "5:Reallocated_Sector_Ct"
        "9:Power_On_Hours"
        "194:Temperature_Celsius"
        "197:Current_Pending_Sector"
        "198:Offline_Uncorrectable"
    )
    
    for attr in "${critical_attrs[@]}"; do
        local id="${attr%%:*}"
        local name="${attr##*:}"
        local value
        value=$(echo "${SMART_BEFORE}" | grep "^${id} " | awk '{print $10}' || echo "N/A")
        
        if [[ "${value}" != "N/A" ]] && [[ "${value}" != "-" ]]; then
            # Special handling for temperature
            if [[ "${name}" == "Temperature_Celsius" ]]; then
                log_info "${name}: ${value}"
            # Check for non-zero values in critical attributes
            elif [[ ${value} -gt 0 ]] && [[ "${name}" != "Power_On_Hours" ]]; then
                log_warn "${name}: ${value} (abnormal value detected)"
            else
                log_info "${name}: ${value}"
            fi
        fi
    done
}

#######################################
# Warning and confirmation
#######################################
confirm_execution() {
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    【 CRITICAL WARNING 】                     ║${NC}"
    echo -e "${RED}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║ Running this test will:                                       ║${NC}"
    echo -e "${RED}║                                                               ║${NC}"
    echo -e "${RED}║ 1. COMPLETELY ERASE all data on ${DEVICE_PATH}               ║${NC}"
    echo -e "${RED}║ 2. Take several hours to over 10 hours                       ║${NC}"
    echo -e "${RED}║ 3. Make the device inaccessible during testing               ║${NC}"
    echo -e "${RED}║                                                               ║${NC}"
    echo -e "${RED}║ Test sequence:                                                ║${NC}"
    echo -e "${RED}║ - SMART short test (~2 minutes)                               ║${NC}"
    echo -e "${RED}║ - badblocks full sector write test (several hours)           ║${NC}"
    echo -e "${RED}║ - SMART long test (several hours)                            ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}Continue? (y/n): ${NC}"
    
    read -r response
    
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        log_info "Test cancelled by user"
        echo "Test cancelled"
        exit 0
    fi
    
    log_info "User confirmed test execution"
}

#######################################
# Run SMART short test
#######################################
run_smart_short_test() {
    log_info "Starting SMART short test..."
    log_command "smartctl -t short ${DEVICE_PATH}"
    
    smartctl -t short "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1
    
    # Get estimated completion time
    local wait_time
    wait_time=$(smartctl -a "${DEVICE_PATH}" | grep "Please wait" | grep -oP '\d+' | head -1 || echo "2")
    
    log_info "Estimated completion time: ${wait_time} minutes"
    echo -ne "${CYAN}Test running"
    
    # Wait until completion
    local elapsed=0
    while true; do
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
        
        # Check test result
        local test_result
        test_result=$(smartctl -l selftest "${DEVICE_PATH}" 2>&1 || true)
        
        if echo "${test_result}" | grep -q "# 1.*Short.*Completed without error"; then
            echo -e " ${GREEN}Completed${NC}"
            log_info "SMART short test completed (elapsed: ${elapsed}s)"
            break
        elif echo "${test_result}" | grep -q "# 1.*Short.*Failed"; then
            echo -e " ${RED}Failed${NC}"
            log_error "SMART short test failed"
            echo "${test_result}" >> "${LOG_FILE}"
            exit 1
        fi
        
        # Timeout (10 minutes)
        if [[ ${elapsed} -gt 600 ]]; then
            echo -e " ${RED}Timeout${NC}"
            log_error "SMART short test timeout"
            exit 1
        fi
    done
    
    # Log test result
    {
        echo "=== SMART Short Test Result ==="
        smartctl -l selftest "${DEVICE_PATH}"
        echo ""
    } >> "${LOG_FILE}"
}

#######################################
# Get sector size
#######################################
get_sector_size() {
    local physical_sector
    local logical_sector
    
    physical_sector=$(blockdev --getpbsz "${DEVICE_PATH}" 2>/dev/null || echo "512")
    logical_sector=$(blockdev --getss "${DEVICE_PATH}" 2>/dev/null || echo "512")
    
    log_info "Physical sector size: ${physical_sector} bytes"
    log_info "Logical sector size: ${logical_sector} bytes"
    
    echo "${physical_sector}"
}

#######################################
# Run badblocks
#######################################
run_badblocks() {
    log_info "Starting badblocks full sector write test..."
    
    local sector_size
    sector_size=$(get_sector_size)
    
    local block_size=$((sector_size / 1024))
    if [[ ${block_size} -lt 1 ]]; then
        block_size=1
    fi
    
    log_command "badblocks -b ${sector_size} -wsv ${DEVICE_PATH}"
    log_info "This test will take several hours..."
    
    # Run badblocks
    # -w: write test (destructive)
    # -s: show progress
    # -v: verbose
    # -b: block size
    
    if badblocks -b "${sector_size}" -wsv "${DEVICE_PATH}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_info "badblocks test completed - no bad sectors found"
    else
        local exit_code=$?
        if [[ ${exit_code} -eq 0 ]]; then
            log_info "badblocks test completed"
        else
            log_error "Error occurred during badblocks test (exit code: ${exit_code})"
        fi
    fi
}

#######################################
# Run SMART long test
#######################################
run_smart_long_test() {
    log_info "Starting SMART long test..."
    log_command "smartctl -t long ${DEVICE_PATH}"
    
    smartctl -t long "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1
    
    # Get estimated completion time
    local wait_minutes
    wait_minutes=$(smartctl -a "${DEVICE_PATH}" | grep "Please wait" | grep -oP '\d+' | tail -1 || echo "120")
    
    log_info "Estimated completion time: ${wait_minutes} minutes"
    
    local total_seconds=$((wait_minutes * 60))
    local check_interval=60  # Check every 1 minute
    local elapsed=0
    
    echo -e "${CYAN}SMART long test running...${NC}"
    
    while true; do
        sleep "${check_interval}"
        elapsed=$((elapsed + check_interval))
        
        # Display progress
        local progress_pct=$((elapsed * 100 / total_seconds))
        if [[ ${progress_pct} -gt 100 ]]; then
            progress_pct=100
        fi
        
        local remaining=$((total_seconds - elapsed))
        if [[ ${remaining} -lt 0 ]]; then
            remaining=0
        fi
        
        local eta_hours=$((remaining / 3600))
        local eta_minutes=$(((remaining % 3600) / 60))
        
        printf "\rProgress: %3d%% | Elapsed: %d min | ETA: %dh%02dm" \
            "${progress_pct}" \
            "$((elapsed / 60))" \
            "${eta_hours}" \
            "${eta_minutes}"
        
        # Check test result
        local test_result
        test_result=$(smartctl -l selftest "${DEVICE_PATH}" 2>&1 || true)
        
        if echo "${test_result}" | grep -q "# 1.*Extended.*Completed without error"; then
            echo -e "\n${GREEN}SMART long test completed${NC}"
            log_info "SMART long test completed (elapsed: $((elapsed / 60)) minutes)"
            break
        elif echo "${test_result}" | grep -q "# 1.*Extended.*Failed"; then
            echo -e "\n${RED}SMART long test failed${NC}"
            log_error "SMART long test failed"
            echo "${test_result}" >> "${LOG_FILE}"
            exit 1
        fi
        
        # Timeout if exceeds 2x estimated time
        if [[ ${elapsed} -gt $((total_seconds * 2)) ]]; then
            echo -e "\n${RED}Timeout${NC}"
            log_error "SMART long test timeout"
            exit 1
        fi
    done
    
    # Log test result
    {
        echo "=== SMART Long Test Result ==="
        smartctl -l selftest "${DEVICE_PATH}"
        echo ""
    } >> "${LOG_FILE}"
}

#######################################
# Compare SMART values
#######################################
compare_smart_values() {
    log_info "Comparing SMART values..."
    
    # Get SMART information after test
    {
        echo "=== SMART Information (After Test) ==="
        smartctl -x "${DEVICE_PATH}"
        echo ""
    } >> "${LOG_FILE}"
    
    SMART_AFTER=$(smartctl -A "${DEVICE_PATH}" 2>&1)
    
    # Compare critical attributes
    local critical_attrs=(
        "1:Raw_Read_Error_Rate"
        "5:Reallocated_Sector_Ct"
        "9:Power_On_Hours"
        "194:Temperature_Celsius"
        "197:Current_Pending_Sector"
        "198:Offline_Uncorrectable"
    )
    
    log_info "Comparing critical indicators:"
    echo "" | tee -a "${LOG_FILE}"
    printf "%-30s | %-10s | %-10s | %s\n" "Attribute" "Before" "After" "Status" | tee -a "${LOG_FILE}"
    printf "%s\n" "--------------------------------------------------------------------------------" | tee -a "${LOG_FILE}"
    
    local has_changes=0
    
    for attr in "${critical_attrs[@]}"; do
        local id="${attr%%:*}"
        local name="${attr##*:}"
        
        local value_before
        local value_after
        
        value_before=$(echo "${SMART_BEFORE}" | grep "^${id} " | awk '{print $10}' || echo "N/A")
        value_after=$(echo "${SMART_AFTER}" | grep "^${id} " | awk '{print $10}' || echo "N/A")
        
        if [[ "${value_before}" == "N/A" ]] || [[ "${value_after}" == "N/A" ]]; then
            continue
        fi
        
        local status="OK"
        # Skip comparison for attributes that naturally increase
        if [[ "${name}" == "Power_On_Hours" ]] || [[ "${name}" == "Temperature_Celsius" ]]; then
            status="--"
        elif [[ "${value_before}" != "${value_after}" ]]; then
            status="${RED}CHANGED${NC}"
            has_changes=1
            log_warn "${name}: ${value_before} -> ${value_after} (value changed)"
        fi
        
        printf "%-30s | %-10s | %-10s | %b\n" "${name}" "${value_before}" "${value_after}" "${status}" | tee -a "${LOG_FILE}"
    done
    
    echo "" | tee -a "${LOG_FILE}"
    
    if [[ ${has_changes} -eq 1 ]]; then
        log_warn "Changes detected in some critical indicators"
        log_warn "The device may have issues"
    else
        log_info "No changes detected in critical indicators"
    fi
}

#######################################
# Test result summary
#######################################
show_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                   Test Completed                              ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Device:${NC} ${DEVICE_PATH}"
    echo -e "${CYAN}Log file:${NC} ${LOG_FILE}"
    echo ""
    echo "View detailed test results in the log file:"
    echo -e "${YELLOW}  cat ${LOG_FILE}${NC}"
    echo -e "${YELLOW}  less ${LOG_FILE}${NC}"
    echo ""
    
    log_info "=================================="
    log_info "All tests completed"
    log_info "Log file: ${LOG_FILE}"
    log_info "=================================="
}

#######################################
# Main process
#######################################
main() {
    show_banner
    check_root
    check_tmux
    check_commands
    select_device
    initialize_log
    check_seagate_firmware
    check_smart_initial
    confirm_execution
    
    log_info "Test start time: $(date '+%Y-%m-%d %H:%M:%S')"
    
    run_smart_short_test
    run_badblocks
    run_smart_long_test
    compare_smart_values
    
    log_info "Test end time: $(date '+%Y-%m-%d %H:%M:%S')"
    
    show_summary
}

# Execute script
main "$@"

