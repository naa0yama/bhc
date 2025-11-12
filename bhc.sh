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

# Log directory base
readonly LOG_BASE="/var/log/bhc"
LOG_DIR=""      # Will be set to specific test directory
LOG_FILE=""

# Global variables
DEVICE=""
DEVICE_PATH=""
SMART_BEFORE=""
SMART_AFTER=""
AUTO_CONFIRM=0  # Non-interactive mode flag
STATE_START_TIME=""  # Test start time for state management
TEST_COUNT_BEFORE=0  # SMART self-test count before test

#######################################
# Show usage
#######################################
show_usage() {
	cat << EOF
Usage: $0 [OPTIONS]

Options:
  -d DEVICE    Device name to test (e.g., sda, sdb)
  -y           Auto-confirm (skip all confirmation prompts)
  -h           Show this help message

Examples:
  $0                    # Interactive mode
  $0 -d sdg -y          # Non-interactive mode with device sdg

EOF
	exit 0
}

#######################################
# Banner display
#######################################
show_banner() {
	echo -e "${CYAN}"
	cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║     Block Device Health Check (bhc.sh)                       ║
║                                                              ║
║     HDD/SSD Acceptance Test Script                           ║
║     - SMART Diagnostics (short/long test)                    ║
║     - badblocks Full Sector Write Test                       ║
║     - Counterfeit & Failure Statistics Check                 ║
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
		"jq:jq"
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

	# Check if smartctl supports JSON output (-j option)
	if ! smartctl --help 2>&1 | grep -q -- '-j'; then
		echo -e "${RED}Error: smartctl does not support -j (JSON output) option${NC}"
		echo "Please upgrade smartmontools to version 7.0 or later"
		echo ""
		echo "To upgrade on Debian 13, run:"
		echo -e "${GREEN}sudo apt update${NC}"
		echo -e "${GREEN}sudo apt install --only-upgrade smartmontools${NC}"
		exit 1
	fi
}

#######################################
# Device selection
#######################################
select_device() {
	# If device is already specified via command-line argument
	if [[ -n "${DEVICE}" ]]; then
		DEVICE_PATH="/dev/${DEVICE}"
		log_info "Using device from command-line: ${DEVICE_PATH}"
	else
		# Interactive mode
		echo ""
		echo -e "${CYAN}=== Available Block Devices ===${NC}"
		echo ""

		lsblk -o NAME,HCTL,MODEL,SERIAL | grep -E '^[a-y]' || {
			echo -e "${RED}Error: No block devices found${NC}"
			exit 1
		}

		echo ""
		echo -ne "${YELLOW}Enter device name to test (e.g., sda): ${NC}"
		read -r DEVICE

		DEVICE_PATH="/dev/${DEVICE}"
	fi

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
# Initialize log directory and output all SMART data
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
	STATE_START_TIME="${timestamp}"

	# Create log directory structure
	mkdir -p "${LOG_BASE}"
	LOG_DIR="${LOG_BASE}/${device_type}_${model}_${serial}_${timestamp}"
	mkdir -p "${LOG_DIR}"

	# Set log file path
	LOG_FILE="${LOG_DIR}/console.log"

	log_info "=================================="
	log_info "Block Device Health Check Started"
	log_info ""
	log_info "Device:       ${DEVICE_PATH}"
	log_info "Type:         ${device_type}"
	log_info "Model:        ${model}"
	log_info "Serial:       ${serial}"
	log_info "Log Dir:      ${LOG_DIR}"
	log_info "=================================="

	# Save initial SMART data as JSON
	log_info "Saving initial SMART data (JSON)..."
	if ! smartctl -j -a "${DEVICE_PATH}" > "${LOG_DIR}/smartctl_start.json" 2>> "${LOG_FILE}"; then
		log_error "Failed to save initial SMART data"
		exit 1
	fi

	# Get initial test count
	TEST_COUNT_BEFORE=$(jq '.ata_smart_self_test_log.standard.count // 0' "${LOG_DIR}/smartctl_start.json")
	log_info "Initial self-test count: ${TEST_COUNT_BEFORE}"

	# Output all SMART information at the beginning (text format for reference)
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

	# Initialize state file
	update_state "init"
}

#######################################
# Update state file
#######################################
update_state() {
	local new_phase=$1
	local timestamp
	timestamp=$(date -Iseconds)

	if [[ -z "${LOG_DIR}" ]] || [[ ! -d "${LOG_DIR}" ]]; then
		log_error "LOG_DIR is not set or does not exist"
		return 1
	fi

	jq -n \
		--arg device "${DEVICE_PATH}" \
		--arg phase "${new_phase}" \
		--arg start "${STATE_START_TIME}" \
		--arg update "${timestamp}" \
		'{device: $device, phase: $phase, start_time: $start, last_update: $update}' \
		> "${LOG_DIR}/state.json"

	log_info "State updated: ${new_phase}"
}

#######################################
# Check for existing state and ask to resume
#######################################
check_resume() {
	# Look for existing incomplete test runs
	local existing_dirs
	mapfile -t existing_dirs < <(find "${LOG_BASE}" -maxdepth 1 -type d -name "*_*_*_*" 2>/dev/null | sort -r)

	if [[ ${#existing_dirs[@]} -eq 0 ]]; then
		return 0
	fi

	# Check each directory for incomplete state
	for dir in "${existing_dirs[@]}"; do
		local state_file="${dir}/state.json"
		if [[ ! -f "${state_file}" ]]; then
			continue
		fi

		local phase
		local device
		phase=$(jq -r '.phase' "${state_file}" 2>/dev/null)
		device=$(jq -r '.device' "${state_file}" 2>/dev/null)

		# Skip if completed or if device doesn't match
		if [[ "${phase}" == "completed" ]] || [[ "${device}" != "${DEVICE_PATH}" ]]; then
			continue
		fi

		# Found incomplete test for this device
		echo ""
		echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
		echo -e "${YELLOW}║          Incomplete Test Found                                ║${NC}"
		echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
		echo ""
		echo -e "${CYAN}Device:${NC}        ${device}"
		echo -e "${CYAN}Log Directory:${NC} ${dir}"
		echo -e "${CYAN}Last Phase:${NC}    ${phase}"
		echo -e "${CYAN}State File:${NC}    ${state_file}"
		echo ""

		if [[ ${AUTO_CONFIRM} -eq 1 ]]; then
			echo -e "${YELLOW}Auto-confirm enabled. Starting fresh test...${NC}"
			log_info "Found incomplete test but auto-confirm is enabled, starting fresh"
			return 0
		fi

		echo -ne "${YELLOW}Do you want to resume this test? (y/n): ${NC}"
		read -r response

		if [[ "${response}" =~ ^[Yy]$ ]]; then
			# Resume from existing state
			LOG_DIR="${dir}"
			LOG_FILE="${LOG_DIR}/console.log"

			log_info "Resuming test from phase: ${phase}"

			# Load necessary state
			STATE_START_TIME=$(jq -r '.start_time' "${state_file}")
			if [[ -f "${LOG_DIR}/smartctl_start.json" ]]; then
				TEST_COUNT_BEFORE=$(jq '.ata_smart_self_test_log.standard.count // 0' "${LOG_DIR}/smartctl_start.json")
			fi

			# Resume based on phase
			case "${phase}" in
				"init"|"smart_short_test")
					log_info "Resuming from SMART short test..."
					run_smart_short_test
					run_badblocks
					run_smart_long_test
					compare_smart_values
					show_summary
					exit 0
					;;
				"badblocks")
					log_info "Resuming from badblocks test..."
					run_badblocks
					run_smart_long_test
					compare_smart_values
					show_summary
					exit 0
					;;
				"smart_long_test")
					log_info "Resuming from SMART long test..."
					run_smart_long_test
					compare_smart_values
					show_summary
					exit 0
					;;
				"compare")
					log_info "Resuming from comparison..."
					compare_smart_values
					show_summary
					exit 0
					;;
			esac
		else
			echo "Starting fresh test..."
			log_info "User chose to start fresh test instead of resuming"
			return 0
		fi
	done
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
	echo -e "${RED}║ 1. COMPLETELY ERASE all data on ${DEVICE_PATH}                      ║${NC}"
	echo -e "${RED}║ 2. Take several hours to over 10 hours                        ║${NC}"
	echo -e "${RED}║ 3. Make the device inaccessible during testing                ║${NC}"
	echo -e "${RED}║                                                               ║${NC}"
	echo -e "${RED}║ Test sequence:                                                ║${NC}"
	echo -e "${RED}║ - SMART short test (~2 minutes)                               ║${NC}"
	echo -e "${RED}║ - badblocks full sector write test (several hours)            ║${NC}"
	echo -e "${RED}║ - SMART long test (several hours)                             ║${NC}"
	echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
	echo ""

	if [[ ${AUTO_CONFIRM} -eq 1 ]]; then
		echo -e "${YELLOW}Auto-confirm enabled. Starting test automatically...${NC}"
		log_info "Test execution auto-confirmed"
	else
		echo -ne "${YELLOW}Continue? (y/n): ${NC}"
		read -r response

		if [[ ! "${response}" =~ ^[Yy]$ ]]; then
			log_info "Test cancelled by user"
			echo "Test cancelled"
			exit 0
		fi

		log_info "User confirmed test execution"
	fi
}

#######################################
# Run SMART short test
#######################################
run_smart_short_test() {
	log_info "Starting SMART short test..."
	update_state "smart_short_test"

	log_command "smartctl -t short ${DEVICE_PATH}"

	if ! smartctl -t short "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1; then
		log_warn "Failed to start test normally. Retrying..."
		smartctl -X "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1 || true
		sleep 5
		smartctl -t short "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1
	fi

	# Get estimated completion time from JSON
	local wait_minutes
	wait_minutes=$(smartctl -j -a "${DEVICE_PATH}" | jq '.ata_smart_data.self_test.polling_minutes.short // 2')

	log_info "Estimated completion time: ${wait_minutes} minutes"

	local total_seconds=$((wait_minutes * 60))
	local check_interval=10
	local elapsed=0

	echo -e "${CYAN}SMART short test running...${NC}"

	# Wait until completion
	while true; do
		sleep "${check_interval}"
		elapsed=$((elapsed + check_interval))

		# Get current SMART data as JSON
		smartctl -j -a "${DEVICE_PATH}" > "${LOG_DIR}/smartctl_current.json" 2>> "${LOG_FILE}"

		local status_value
		local remaining
		local test_count_now
		status_value=$(jq '.ata_smart_data.self_test.status.value' "${LOG_DIR}/smartctl_current.json")
		remaining=$(jq '.ata_smart_data.self_test.status.remaining_percent // 0' "${LOG_DIR}/smartctl_current.json")
		test_count_now=$(jq '.ata_smart_self_test_log.standard.count // 0' "${LOG_DIR}/smartctl_current.json")

		# Display progress
		if [[ ${remaining} -gt 0 ]] && [[ ${status_value} -ge 240 ]] && [[ ${status_value} -le 255 ]]; then
			# Test in progress
			local progress=$((100 - remaining))
			printf "\rProgress: %3d%% | Elapsed: %d sec | Remaining: ~%d%%" \
				"${progress}" "${elapsed}" "${remaining}"
		else
			local progress_pct=$((elapsed * 100 / total_seconds))
			if [[ ${progress_pct} -gt 100 ]]; then
				progress_pct=100
			fi
			printf "\rProgress: %3d%% | Elapsed: %d sec" "${progress_pct}" "${elapsed}"
		fi

		# Check test completion using composite judgment
		if [[ ${status_value} -eq 0 ]]; then
			# Idle state - check if test actually completed
			if [[ ${test_count_now} -gt ${TEST_COUNT_BEFORE} ]]; then
				# New test result added - verify it's a short test
				local latest_type
				local latest_passed
				latest_type=$(jq '.ata_smart_self_test_log.standard.table[0].type.value' "${LOG_DIR}/smartctl_current.json")
				latest_passed=$(jq '.ata_smart_self_test_log.standard.table[0].status.passed' "${LOG_DIR}/smartctl_current.json")

				if [[ ${latest_type} -eq 1 ]] && [[ "${latest_passed}" == "true" ]]; then
					echo -e "\n${GREEN}SMART short test completed${NC}"
					log_info "SMART short test completed (elapsed: ${elapsed}s)"
					break
				elif [[ ${latest_type} -eq 1 ]]; then
					echo -e "\n${RED}SMART short test failed${NC}"
					log_error "SMART short test failed"
					jq '.ata_smart_self_test_log.standard.table[0]' "${LOG_DIR}/smartctl_current.json" >> "${LOG_FILE}"
					exit 1
				fi
			fi
		elif [[ ${status_value} -ge 1 ]] && [[ ${status_value} -le 8 ]]; then
			# Test failed
			echo -e "\n${RED}SMART short test failed (status: ${status_value})${NC}"
			log_error "SMART short test failed with status value: ${status_value}"
			exit 1
		fi

		# Timeout (10 minutes or 2x estimated time, whichever is longer)
		local max_wait=$((total_seconds * 2))
		if [[ ${max_wait} -lt 600 ]]; then
			max_wait=600
		fi

		if [[ ${elapsed} -gt ${max_wait} ]]; then
			echo -e "\n${RED}Timeout${NC}"
			log_error "SMART short test timeout"
			exit 1
		fi
	done

	# Update test count
	TEST_COUNT_BEFORE=${test_count_now}

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

	log_info "Physical sector size: ${physical_sector} bytes" >&2
	log_info "Logical sector size: ${logical_sector} bytes" >&2

	echo "${physical_sector}"
}

#######################################
# Run badblocks
#######################################
run_badblocks() {
	log_info "Starting badblocks full sector write test..."
	update_state "badblocks"

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
	update_state "smart_long_test"

	log_info "Checking for existing tests..."
	if smartctl -l selftest "${DEVICE_PATH}" 2>&1 | grep -q "Self-test execution status:.*in progress"; then
		log_warn "Existing test in progress. Aborting it..."
		smartctl -X "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1 || true
		sleep 5
	fi

	log_command "smartctl -t long ${DEVICE_PATH}"

	if ! smartctl -t long "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1; then
		log_warn "Failed to start test normally. Retrying with force option..."
		smartctl -X "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1 || true
		sleep 5
		smartctl -t long "${DEVICE_PATH}" >> "${LOG_FILE}" 2>&1
	fi

	# Get estimated completion time from JSON
	local wait_minutes
	wait_minutes=$(smartctl -j -a "${DEVICE_PATH}" | jq '.ata_smart_data.self_test.polling_minutes.extended // 120')

	log_info "Estimated completion time: ${wait_minutes} minutes ($(printf "%.1f" "$(echo "${wait_minutes} / 60" | bc -l)") hours)"

	local total_seconds=$((wait_minutes * 60))
	local check_interval=60  # Check every 1 minute
	local elapsed=0

	echo -e "${CYAN}SMART long test running...${NC}"

	while true; do
		sleep "${check_interval}"
		elapsed=$((elapsed + check_interval))

		# Get current SMART data as JSON
		smartctl -j -a "${DEVICE_PATH}" > "${LOG_DIR}/smartctl_current.json" 2>> "${LOG_FILE}"

		local status_value
		local remaining
		local test_count_now
		status_value=$(jq '.ata_smart_data.self_test.status.value' "${LOG_DIR}/smartctl_current.json")
		remaining=$(jq '.ata_smart_data.self_test.status.remaining_percent // 0' "${LOG_DIR}/smartctl_current.json")
		test_count_now=$(jq '.ata_smart_self_test_log.standard.count // 0' "${LOG_DIR}/smartctl_current.json")

		# Display progress
		if [[ ${remaining} -gt 0 ]] && [[ ${status_value} -ge 240 ]] && [[ ${status_value} -le 255 ]]; then
			# Test in progress - use remaining_percent for accurate progress
			local progress=$((100 - remaining))
			local elapsed_min=$((elapsed / 60))
			local eta_min=$((wait_minutes * remaining / 100))
			local eta_hours=$((eta_min / 60))
			local eta_min_rem=$((eta_min % 60))

			printf "\rProgress: %3d%% | Elapsed: %d min | Remaining: ~%d%% (~%dh%02dm)" \
				"${progress}" "${elapsed_min}" "${remaining}" "${eta_hours}" "${eta_min_rem}"
		else
			# Use estimated time for progress
			local progress_pct=$((elapsed * 100 / total_seconds))
			if [[ ${progress_pct} -gt 100 ]]; then
				progress_pct=100
			fi

			local remaining_sec=$((total_seconds - elapsed))
			if [[ ${remaining_sec} -lt 0 ]]; then
				remaining_sec=0
			fi

			local eta_hours=$((remaining_sec / 3600))
			local eta_minutes=$(((remaining_sec % 3600) / 60))

			printf "\rProgress: %3d%% | Elapsed: %d min | ETA: %dh%02dm" \
				"${progress_pct}" "$((elapsed / 60))" "${eta_hours}" "${eta_minutes}"
		fi

		# Check test completion using composite judgment
		if [[ ${status_value} -eq 0 ]]; then
			# Idle state - check if test actually completed
			if [[ ${test_count_now} -gt ${TEST_COUNT_BEFORE} ]]; then
				# New test result added - verify it's an extended test
				local latest_type
				local latest_passed
				latest_type=$(jq '.ata_smart_self_test_log.standard.table[0].type.value' "${LOG_DIR}/smartctl_current.json")
				latest_passed=$(jq '.ata_smart_self_test_log.standard.table[0].status.passed' "${LOG_DIR}/smartctl_current.json")

				if [[ ${latest_type} -eq 2 ]] && [[ "${latest_passed}" == "true" ]]; then
					echo -e "\n${GREEN}SMART long test completed${NC}"
					log_info "SMART long test completed (elapsed: $((elapsed / 60)) minutes)"
					break
				elif [[ ${latest_type} -eq 2 ]]; then
					echo -e "\n${RED}SMART long test failed${NC}"
					log_error "SMART long test failed"
					jq '.ata_smart_self_test_log.standard.table[0]' "${LOG_DIR}/smartctl_current.json" >> "${LOG_FILE}"
					exit 1
				fi
			fi
		elif [[ ${status_value} -ge 1 ]] && [[ ${status_value} -le 8 ]]; then
			# Test failed
			echo -e "\n${RED}SMART long test failed (status: ${status_value})${NC}"
			log_error "SMART long test failed with status value: ${status_value}"
			exit 1
		fi

		# Timeout if exceeds 2x estimated time
		if [[ ${elapsed} -gt $((total_seconds * 2)) ]]; then
			echo -e "\n${RED}Timeout${NC}"
			log_error "SMART long test timeout (exceeded $((total_seconds * 2 / 60)) minutes)"
			exit 1
		fi
	done

	# Update test count
	TEST_COUNT_BEFORE=${test_count_now}

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
	update_state "compare"

	# Save final SMART data as JSON
	log_info "Saving final SMART data (JSON)..."
	if ! smartctl -j -a "${DEVICE_PATH}" > "${LOG_DIR}/smartctl_end.json" 2>> "${LOG_FILE}"; then
		log_error "Failed to save final SMART data"
		exit 1
	fi

	# Get SMART information after test (text format for reference)
	{
		echo "=== SMART Information (After Test) ==="
		smartctl -x "${DEVICE_PATH}"
		echo ""
	} >> "${LOG_FILE}"

	SMART_AFTER=$(smartctl -A "${DEVICE_PATH}" 2>&1)

	# Compare critical attributes using JSON
	local critical_attrs=(
		"1:Raw_Read_Error_Rate"
		"5:Reallocated_Sector_Ct"
		"9:Power_On_Hours"
		"194:Temperature_Celsius"
		"197:Current_Pending_Sector"
		"198:Offline_Uncorrectable"
	)

	log_info "Comparing critical indicators (JSON-based):"
	echo "" | tee -a "${LOG_FILE}"
	printf "%-30s | %-10s | %-10s | %s\n" "Attribute" "Before" "After" "Status" | tee -a "${LOG_FILE}"
	printf "%s\n" "--------------------------------------------------------------------------------" | tee -a "${LOG_FILE}"

	local has_changes=0

	for attr in "${critical_attrs[@]}"; do
		local id="${attr%%:*}"
		local name="${attr##*:}"

		local value_before
		local value_after

		# Extract values from JSON using jq
		value_before=$(jq ".ata_smart_attributes.table[] | select(.id == ${id}) | .raw.value" "${LOG_DIR}/smartctl_start.json" 2>/dev/null || echo "null")
		value_after=$(jq ".ata_smart_attributes.table[] | select(.id == ${id}) | .raw.value" "${LOG_DIR}/smartctl_end.json" 2>/dev/null || echo "null")

		if [[ "${value_before}" == "null" ]] || [[ "${value_after}" == "null" ]]; then
			# Attribute not found in JSON, try text format as fallback
			value_before=$(echo "${SMART_BEFORE}" | grep "^${id} " | awk '{print $10}' || echo "N/A")
			value_after=$(echo "${SMART_AFTER}" | grep "^${id} " | awk '{print $10}' || echo "N/A")

			if [[ "${value_before}" == "N/A" ]] || [[ "${value_after}" == "N/A" ]]; then
				continue
			fi
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

	# Mark as completed
	update_state "completed"
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
# Parse command-line arguments
#######################################
parse_arguments() {
	while getopts "d:yh" opt; do
		case ${opt} in
			d)
				DEVICE="${OPTARG}"
				;;
			y)
				AUTO_CONFIRM=1
				;;
			h)
				show_usage
				;;
			\?)
				echo -e "${RED}Invalid option: -${OPTARG}${NC}" >&2
				show_usage
				;;
			:)
				echo -e "${RED}Option -${OPTARG} requires an argument${NC}" >&2
				show_usage
				;;
		esac
	done
}

#######################################
# Main process
#######################################
main() {
	# Parse command-line arguments first
	parse_arguments "$@"

	show_banner
	check_root
	check_tmux
	check_commands
	select_device

	# Check for existing incomplete tests and offer to resume
	check_resume

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
