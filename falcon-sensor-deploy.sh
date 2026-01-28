#!/bin/bash

#===============================================================================
# CrowdStrike Falcon Sensor Interactive Deployment Script
# Version: 2.0.0
# 
# Features:
#   - Interactive variable input with validation
#   - Prerequisite checking
#   - AWS resource discovery
#   - Dry-run mode
#   - Checkpoint/resume capability
#   - Automatic rollback on failure
#   - Comprehensive testing and validation
#   - Detailed deployment summary
#===============================================================================

set -o pipefail

#===============================================================================
# GLOBAL CONFIGURATION
#===============================================================================
SCRIPT_VERSION="2.1.0"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HOME}/.falcon-deploy"
STATE_FILE="${STATE_DIR}/deployment-state.json"
LOG_FILE="${STATE_DIR}/deployment-$(date +%Y%m%d-%H%M%S).log"

# Deployment state tracking
declare -a ROLLBACK_ACTIONS
declare -a CREATED_RESOURCES

# Default values
DRY_RUN=false
INTERACTIVE=true
FORCE_RESTART=false
VERBOSE=false
TASK_DEF_ARN=""
IMAGE_PULL_TOKEN=""

# Multi-account deployment
DEPLOY_MODE="single"
CROSS_ACCOUNT_ROLE="FalconSensorDeployRole"
OU_IDS=""
CONTINUE_ON_FAILURE=true
SENSOR_PLATFORM="x86_64"
declare -A ACCOUNT_RESULTS
declare -a TARGET_ACCOUNTS

#===============================================================================
# COLORS AND FORMATTING
#===============================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' BOLD='' DIM='' NC=''
fi

#===============================================================================
# LOGGING FUNCTIONS
#===============================================================================
init_logging() {
    mkdir -p "$STATE_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
}

print_header() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}$1${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log "INFO" "=== $1 ==="
}

print_subheader() {
    echo ""
    echo -e "${BLUE}━━━ $1 ━━━${NC}"
    echo ""
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO" "$1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    log "SUCCESS" "$1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
    log "WARNING" "$1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
    log "ERROR" "$1"
}

print_dry_run() {
    echo -e "${MAGENTA}[DRY-RUN]${NC} $1"
    log "DRY-RUN" "$1"
}

print_step() {
    local step_num="$1"
    local total="$2"
    local description="$3"
    echo ""
    echo -e "${WHITE}[Step ${step_num}/${total}]${NC} ${BOLD}${description}${NC}"
    log "STEP" "[$step_num/$total] $description"
}

#===============================================================================
# STATE MANAGEMENT
#===============================================================================
init_state() {
    mkdir -p "$STATE_DIR"
    
    if [[ -f "$STATE_FILE" ]] && [[ "$FORCE_RESTART" != "true" ]]; then
        print_info "Found existing deployment state"
        return 0
    fi
    
    cat > "$STATE_FILE" << 'EOF'
{
    "version": "2.1.0",
    "started_at": "",
    "last_updated": "",
    "deployment_type": "",
    "status": "initialized",
    "checkpoints": {},
    "variables": {},
    "created_resources": [],
    "rollback_actions": []
}
EOF
    
    update_state ".started_at" "$(date -Iseconds)"
}

update_state() {
    local key="$1"
    local value="$2"
    
    if [[ -f "$STATE_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        jq "$key = \"$value\"" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
}

set_checkpoint() {
    local checkpoint_name="$1"
    local status="${2:-completed}"
    
    if [[ -f "$STATE_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        jq ".checkpoints[\"$checkpoint_name\"] = {\"status\": \"$status\", \"timestamp\": \"$(date -Iseconds)\"}" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
    
    print_success "Checkpoint: $checkpoint_name"
}

check_checkpoint() {
    local checkpoint_name="$1"
    
    if [[ -f "$STATE_FILE" ]]; then
        local status
        status=$(jq -r ".checkpoints[\"$checkpoint_name\"].status // empty" "$STATE_FILE")
        [[ "$status" == "completed" ]] && return 0
    fi
    return 1
}

save_variable() {
    local var_name="$1"
    local var_value="$2"
    
    if [[ -f "$STATE_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        # Escape the value for JSON
        local escaped_value
        escaped_value=$(echo "$var_value" | sed 's/\\/\\\\/g; s/"/\\"/g')
        jq ".variables[\"$var_name\"] = \"$escaped_value\"" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
}

load_variable() {
    local var_name="$1"
    
    if [[ -f "$STATE_FILE" ]]; then
        jq -r ".variables[\"$var_name\"] // empty" "$STATE_FILE"
    fi
}

add_rollback_action() {
    local action_type="$1"
    local resource_id="$2"
    local cleanup_command="$3"
    
    if [[ -f "$STATE_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        jq ".rollback_actions += [{\"type\": \"$action_type\", \"resource\": \"$resource_id\", \"command\": $(echo "$cleanup_command" | jq -R .), \"timestamp\": \"$(date -Iseconds)\"}]" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
    
    ROLLBACK_ACTIONS+=("$cleanup_command")
    CREATED_RESOURCES+=("$resource_id")
}

add_created_resource() {
    local resource_type="$1"
    local resource_id="$2"
    
    if [[ -f "$STATE_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        jq ".created_resources += [{\"type\": \"$resource_type\", \"id\": \"$resource_id\", \"timestamp\": \"$(date -Iseconds)\"}]" "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
}

#===============================================================================
# ERROR HANDLING AND ROLLBACK
#===============================================================================
perform_rollback() {
    print_header "Rolling Back Changes"
    
    local rollback_count=${#ROLLBACK_ACTIONS[@]}
    local success_count=0
    local fail_count=0
    
    for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
        local action="${ROLLBACK_ACTIONS[$i]}"
        print_info "Executing: $action"
        
        if $DRY_RUN; then
            print_dry_run "Would execute: $action"
            ((success_count++))
        else
            if eval "$action" 2>/dev/null; then
                print_success "Rolled back successfully"
                ((success_count++))
            else
                print_error "Rollback action failed: $action"
                ((fail_count++))
            fi
        fi
    done
    
    echo ""
    print_subheader "Rollback Summary"
    echo "  Total actions: $rollback_count"
    echo "  Successful: $success_count"
    echo "  Failed: $fail_count"
    
    if [[ $fail_count -gt 0 ]]; then
        print_warning "Some rollback actions failed. Manual cleanup may be required."
    else
        print_success "Rollback completed successfully"
    fi
}

cleanup_on_error() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 130 ]]; then
        print_error "Deployment failed with exit code: $exit_code"
        
        if [[ ${#ROLLBACK_ACTIONS[@]} -gt 0 ]]; then
            echo ""
            print_warning "Initiating rollback of created resources..."
            echo ""
            
            if $INTERACTIVE; then
                read -r -p "Do you want to rollback changes? [Y/n]: " response
                response=${response:-Y}
            else
                response="Y"
            fi
            
            if [[ "$response" =~ ^[Yy]$ ]]; then
                perform_rollback
            else
                print_warning "Rollback skipped. Resources may need manual cleanup."
                print_info "Created resources are logged in: $STATE_FILE"
            fi
        fi
        
        update_state ".status" "failed"
    fi
}

trap cleanup_on_error EXIT

die() {
    print_error "$1"
    exit 1
}

#===============================================================================
# PREREQUISITE CHECKS
#===============================================================================
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    local all_passed=true
    local checks_total=0
    local checks_passed=0
    
    declare -A required_tools=(
        ["aws"]="AWS CLI - Install from https://aws.amazon.com/cli/"
        ["docker"]="Docker - Install from https://docs.docker.com/get-docker/"
        ["jq"]="jq - Install with: apt-get install jq / brew install jq"
        ["curl"]="curl - Install with: apt-get install curl / brew install curl"
    )
    
    declare -A optional_tools=(
        ["helm"]="Helm - Required for EKS deployments"
        ["kubectl"]="kubectl - Required for EKS deployments"
    )
    
    print_subheader "Required Tools"
    
    for tool in "${!required_tools[@]}"; do
        ((checks_total++))
        printf "  %-12s" "$tool"
        
        if command -v "$tool" &> /dev/null; then
            local version
            case "$tool" in
                aws) version=$(aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2) ;;
                docker) version=$(docker --version 2>&1 | cut -d' ' -f3 | tr -d ',') ;;
                jq) version=$(jq --version 2>&1) ;;
                curl) version=$(curl --version 2>&1 | head -1 | cut -d' ' -f2) ;;
                *) version="unknown" ;;
            esac
            echo -e "${GREEN}✓${NC} (v${version})"
            ((checks_passed++))
        else
            echo -e "${RED}✗${NC} Not installed"
            echo -e "    ${DIM}${required_tools[$tool]}${NC}"
            all_passed=false
        fi
    done
    
    print_subheader "Optional Tools (for EKS)"
    
    for tool in "${!optional_tools[@]}"; do
        printf "  %-12s" "$tool"
        
        if command -v "$tool" &> /dev/null; then
            local version
            case "$tool" in
                helm) version=$(helm version --short 2>&1 | cut -d'+' -f1) ;;
                kubectl) version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "unknown") ;;
                *) version="unknown" ;;
            esac
            echo -e "${GREEN}✓${NC} (${version})"
        else
            echo -e "${YELLOW}○${NC} Not installed (optional)"
            echo -e "    ${DIM}${optional_tools[$tool]}${NC}"
        fi
    done
    
    print_subheader "Service Checks"
    
    ((checks_total++))
    printf "  %-20s" "Docker daemon"
    if docker info &> /dev/null; then
        echo -e "${GREEN}✓${NC} Running"
        ((checks_passed++))
    else
        echo -e "${RED}✗${NC} Not running"
        all_passed=false
    fi
    
    ((checks_total++))
    printf "  %-20s" "AWS credentials"
    if aws sts get-caller-identity &> /dev/null; then
        local aws_account
        aws_account=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
        echo -e "${GREEN}✓${NC} Configured (Account: $aws_account)"
        ((checks_passed++))
    else
        echo -e "${RED}✗${NC} Not configured or invalid"
        all_passed=false
    fi
    
    if command -v kubectl &> /dev/null; then
        printf "  %-20s" "Kubernetes context"
        if kubectl cluster-info &> /dev/null 2>&1; then
            local context
            context=$(kubectl config current-context 2>/dev/null)
            echo -e "${GREEN}✓${NC} Connected ($context)"
        else
            echo -e "${YELLOW}○${NC} Not connected (required for EKS)"
        fi
    fi
    
    if [[ "$DEPLOY_MODE" != "single" ]]; then
        ((checks_total++))
        printf "  %-20s" "AWS Organizations"
        if aws organizations describe-organization &> /dev/null; then
            local org_id
            org_id=$(aws organizations describe-organization --query 'Organization.Id' --output text 2>/dev/null)
            echo -e "${GREEN}✓${NC} Accessible (Org: $org_id)"
            ((checks_passed++))
        else
            echo -e "${RED}✗${NC} Cannot access AWS Organizations"
            all_passed=false
        fi
    fi

    ((checks_total++))
    printf "  %-20s" "Disk space"
    local available_space
    available_space=$(df -BG . 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ "${available_space:-0}" -ge 5 ]]; then
        echo -e "${GREEN}✓${NC} ${available_space}GB available"
        ((checks_passed++))
    else
        echo -e "${YELLOW}⚠${NC} Low disk space (${available_space}GB)"
    fi
    
    ((checks_total++))
    printf "  %-20s" "Network (CrowdStrike)"
    if curl -s --connect-timeout 5 https://api.crowdstrike.com > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Reachable"
        ((checks_passed++))
    else
        echo -e "${RED}✗${NC} Cannot reach CrowdStrike API"
        all_passed=false
    fi
    
    echo ""
    echo -e "  ${BOLD}Prerequisites Check: ${checks_passed}/${checks_total} passed${NC}"
    
    if [[ "$all_passed" != "true" ]]; then
        echo ""
        print_error "Some required prerequisites are missing. Please install them and try again."
        return 1
    fi
    
    print_success "All required prerequisites are met"
    set_checkpoint "prerequisites_check"
    return 0
}

#===============================================================================
# INTERACTIVE INPUT
#===============================================================================
prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local secret="${4:-false}"
    local validation="${5:-}"
    
    local value=""
    local saved_value
    saved_value=$(load_variable "$var_name")
    
    if [[ -n "$saved_value" ]]; then
        default="$saved_value"
    fi
    
    while true; do
        if [[ -n "$default" ]] && [[ "$secret" != "true" ]]; then
            echo -en "${CYAN}?${NC} $prompt [${default}]: "
        else
            echo -en "${CYAN}?${NC} $prompt: "
        fi
        
        if [[ "$secret" == "true" ]]; then
            read -rs value
            echo ""
        else
            read -r value
        fi
        
        value="${value:-$default}"
        
        if [[ -n "$validation" ]]; then
            if ! $validation "$value"; then
                print_error "Invalid input. Please try again."
                continue
            fi
        fi
        
        if [[ -z "$value" ]]; then
            print_error "This field is required."
            continue
        fi
        
        break
    done
    
    if [[ "$secret" != "true" ]]; then
        save_variable "$var_name" "$value"
    fi
    
    echo "$value"
}

prompt_select() {
    local prompt="$1"
    local var_name="$2"
    shift 2
    local options=("$@")
    
    local saved_value
    saved_value=$(load_variable "$var_name")
    
    echo -e "${CYAN}?${NC} $prompt"
    
    local i=1
    for opt in "${options[@]}"; do
        if [[ "$opt" == "$saved_value" ]]; then
            echo -e "  ${GREEN}${i})${NC} $opt ${DIM}(previous selection)${NC}"
        else
            echo "  $i) $opt"
        fi
        ((i++))
    done
    
    while true; do
        echo -en "  Select [1-${#options[@]}]: "
        read -r selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "${#options[@]}" ]]; then
            local value="${options[$((selection-1))]}"
            save_variable "$var_name" "$value"
            echo "$value"
            return 0
        fi
        
        print_error "Invalid selection. Please enter a number between 1 and ${#options[@]}."
    done
}

prompt_confirm() {
    local prompt="$1"
    local default="${2:-Y}"
    
    local yn_prompt
    if [[ "$default" == "Y" ]]; then
        yn_prompt="[Y/n]"
    else
        yn_prompt="[y/N]"
    fi
    
    echo -en "${CYAN}?${NC} $prompt $yn_prompt: "
    read -r response
    response="${response:-$default}"
    
    [[ "$response" =~ ^[Yy]$ ]]
}

#===============================================================================
# VALIDATION FUNCTIONS
#===============================================================================
validate_falcon_client_id() {
    local value="$1"
    [[ ${#value} -ge 20 ]] && return 0
    return 1
}

validate_falcon_cid() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9]+-[A-Za-z0-9]+$ ]] || [[ "$value" =~ ^[A-Za-z0-9]{32}-[A-Za-z0-9]{2}$ ]] && return 0
    return 1
}

validate_aws_region() {
    local value="$1"
    [[ "$value" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] && return 0
    return 1
}

#===============================================================================
# INTERACTIVE CONFIGURATION
#===============================================================================
collect_configuration() {
    print_header "Configuration"
    
    if check_checkpoint "configuration_collected" && ! $FORCE_RESTART; then
        print_info "Using previously saved configuration"
        
        FALCON_CLIENT_ID=$(load_variable "FALCON_CLIENT_ID")
        FALCON_CID=$(load_variable "FALCON_CID")
        FALCON_CLOUD=$(load_variable "FALCON_CLOUD")
        AWS_REGION=$(load_variable "AWS_REGION")
        DEPLOYMENT_TYPE=$(load_variable "DEPLOYMENT_TYPE")
        HELM_NAMESPACE=$(load_variable "HELM_NAMESPACE")
        HELM_RELEASE_NAME=$(load_variable "HELM_RELEASE_NAME")
        ECR_REPO_NAME=$(load_variable "ECR_REPO_NAME")
        SENSOR_TAGS=$(load_variable "SENSOR_TAGS")
        SENSOR_PLATFORM=$(load_variable "SENSOR_PLATFORM")
        SENSOR_PLATFORM="${SENSOR_PLATFORM:-x86_64}"
        local saved_deploy_mode
        saved_deploy_mode=$(load_variable "DEPLOY_MODE")
        DEPLOY_MODE="${saved_deploy_mode:-$DEPLOY_MODE}"
        local saved_cross_role
        saved_cross_role=$(load_variable "CROSS_ACCOUNT_ROLE")
        CROSS_ACCOUNT_ROLE="${saved_cross_role:-$CROSS_ACCOUNT_ROLE}"
        local saved_ou_ids
        saved_ou_ids=$(load_variable "OU_IDS")
        OU_IDS="${saved_ou_ids:-$OU_IDS}"

        if prompt_confirm "Would you like to modify the configuration?"; then
            FORCE_RESTART=true
        else
            return 0
        fi
    fi
    
    print_subheader "Deployment Type"
    
    DEPLOYMENT_TYPE=$(prompt_select "Select deployment target" "DEPLOYMENT_TYPE" \
        "ECS Fargate (Container Sensor - Sidecar)" \
        "EKS (Node Sensor - DaemonSet via Helm)" \
        "Both (ECS Fargate + EKS)")
    
    print_subheader "Sensor Platform Architecture"

    SENSOR_PLATFORM=$(prompt_select "Select sensor platform architecture" "SENSOR_PLATFORM" \
        "x86_64" "aarch64")

    print_subheader "Deployment Scope"

    local deploy_scope
    deploy_scope=$(prompt_select "Select deployment scope" "DEPLOY_SCOPE" \
        "Single Account" \
        "AWS Organization (all accounts)" \
        "Specific OUs")

    case "$deploy_scope" in
        "Single Account")
            DEPLOY_MODE="single"
            ;;
        "AWS Organization (all accounts)")
            DEPLOY_MODE="org"
            CROSS_ACCOUNT_ROLE=$(prompt_input "Enter cross-account IAM role name" "CROSS_ACCOUNT_ROLE" "$CROSS_ACCOUNT_ROLE")
            ;;
        "Specific OUs")
            DEPLOY_MODE="ou"
            CROSS_ACCOUNT_ROLE=$(prompt_input "Enter cross-account IAM role name" "CROSS_ACCOUNT_ROLE" "$CROSS_ACCOUNT_ROLE")
            OU_IDS=$(prompt_input "Enter comma-separated OU IDs (e.g., ou-xxxx-xxxxxxxx,ou-yyyy-yyyyyyyy)" "OU_IDS")
            ;;
    esac

    save_variable "DEPLOY_MODE" "$DEPLOY_MODE"
    save_variable "CROSS_ACCOUNT_ROLE" "$CROSS_ACCOUNT_ROLE"
    save_variable "OU_IDS" "$OU_IDS"

    print_subheader "CrowdStrike API Credentials"
    echo -e "${DIM}Create API credentials at: https://falcon.crowdstrike.com/api-clients-and-keys${NC}"
    echo -e "${DIM}Required scopes: Falcon Images Download (Read), Sensor Download (Read)${NC}"
    echo ""
    
    FALCON_CLIENT_ID=$(prompt_input "Enter Falcon API Client ID" "FALCON_CLIENT_ID" "${FALCON_CLIENT_ID:-}" "false" "validate_falcon_client_id")
    FALCON_CLIENT_SECRET=$(prompt_input "Enter Falcon API Client Secret" "FALCON_CLIENT_SECRET" "" "true")
    
    echo ""
    echo -e "${DIM}Find your CID at: Host setup and management > Deploy > Sensor downloads${NC}"
    FALCON_CID=$(prompt_input "Enter Falcon CID (with checksum)" "FALCON_CID" "${FALCON_CID:-}" "false" "validate_falcon_cid")
    
    print_subheader "CrowdStrike Cloud Region"
    
    FALCON_CLOUD=$(prompt_select "Select CrowdStrike cloud region" "FALCON_CLOUD" \
        "us-1" "us-2" "eu-1" "us-gov-1" "us-gov-2")
    
    print_subheader "AWS Configuration"
    
    local current_region
    current_region=$(aws configure get region 2>/dev/null || echo "us-east-1")
    
    AWS_REGION=$(prompt_input "Enter AWS Region" "AWS_REGION" "$current_region" "false" "validate_aws_region")
    
    if [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]]; then
        print_subheader "EKS Configuration"
        HELM_NAMESPACE=$(prompt_input "Enter Kubernetes namespace for Falcon" "HELM_NAMESPACE" "falcon-system")
        HELM_RELEASE_NAME=$(prompt_input "Enter Helm release name" "HELM_RELEASE_NAME" "falcon-sensor")
    fi
    
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        print_subheader "ECS Configuration"
        ECR_REPO_NAME=$(prompt_input "Enter ECR repository name for sensor" "ECR_REPO_NAME" "falcon-sensor/falcon-container")
    fi
    
    print_subheader "Optional Configuration"
    
    if prompt_confirm "Do you want to add sensor tags for grouping?" "N"; then
        SENSOR_TAGS=$(prompt_input "Enter comma-separated tags (e.g., production,web-tier)" "SENSOR_TAGS" "")
    fi
    
    set_checkpoint "configuration_collected"
    
    echo ""
    print_subheader "Configuration Summary"
    echo "  Deployment Type:    $DEPLOYMENT_TYPE"
    echo "  Sensor Platform:    $SENSOR_PLATFORM"
    echo "  Deploy Mode:        $DEPLOY_MODE"
    [[ "$DEPLOY_MODE" != "single" ]] && echo "  Cross-Account Role: $CROSS_ACCOUNT_ROLE"
    [[ "$DEPLOY_MODE" == "ou" ]] && echo "  OU IDs:             $OU_IDS"
    echo "  Falcon Cloud:       $FALCON_CLOUD"
    echo "  Falcon CID:         ${FALCON_CID:0:10}..."
    echo "  AWS Region:         $AWS_REGION"
    [[ -n "${HELM_NAMESPACE:-}" ]] && echo "  K8s Namespace:      $HELM_NAMESPACE"
    [[ -n "${ECR_REPO_NAME:-}" ]] && echo "  ECR Repository:     $ECR_REPO_NAME"
    [[ -n "${SENSOR_TAGS:-}" ]] && echo "  Sensor Tags:        $SENSOR_TAGS"
    echo ""
    
    if ! prompt_confirm "Is this configuration correct?"; then
        print_info "Restarting configuration..."
        FORCE_RESTART=true
        collect_configuration
    fi
}

#===============================================================================
# AWS RESOURCE DISCOVERY
#===============================================================================
discover_aws_resources() {
    print_header "Discovering AWS Resources"
    
    local aws_account_id
    aws_account_id=$(aws sts get-caller-identity --query 'Account' --output text)
    
    echo -e "  ${BOLD}AWS Account:${NC} $aws_account_id"
    echo -e "  ${BOLD}Region:${NC} $AWS_REGION"
    echo ""
    
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        print_subheader "ECS Fargate Resources"
        
        echo -e "  ${BOLD}ECS Clusters:${NC}"
        local clusters
        clusters=$(aws ecs list-clusters --region "$AWS_REGION" --query 'clusterArns[*]' --output text 2>/dev/null)
        
        if [[ -n "$clusters" ]]; then
            local cluster_count=0
            local fargate_service_count=0
            
            for cluster_arn in $clusters; do
                local cluster_name
                cluster_name=$(basename "$cluster_arn")
                
                local cluster_info
                cluster_info=$(aws ecs describe-clusters --clusters "$cluster_arn" --region "$AWS_REGION" \
                    --query 'clusters[0].{status:status,services:activeServicesCount,tasks:runningTasksCount}' --output json 2>/dev/null)
                
                local status services tasks
                status=$(echo "$cluster_info" | jq -r '.status')
                services=$(echo "$cluster_info" | jq -r '.services')
                tasks=$(echo "$cluster_info" | jq -r '.tasks')
                
                echo -e "    • ${GREEN}$cluster_name${NC}"
                echo -e "      Status: $status | Services: $services | Running Tasks: $tasks"
                ((cluster_count++))
                
                local service_arns
                service_arns=$(aws ecs list-services --cluster "$cluster_arn" --region "$AWS_REGION" --query 'serviceArns[*]' --output text 2>/dev/null)
                
                if [[ -n "$service_arns" ]]; then
                    for service_arn in $service_arns; do
                        local service_name
                        service_name=$(basename "$service_arn")
                        
                        local launch_type
                        launch_type=$(aws ecs describe-services --cluster "$cluster_arn" --services "$service_arn" --region "$AWS_REGION" \
                            --query 'services[0].launchType' --output text 2>/dev/null)
                        
                        if [[ "$launch_type" == "FARGATE" ]]; then
                            echo -e "      └─ ${CYAN}$service_name${NC} (Fargate) ${YELLOW}← Can be protected${NC}"
                            ((fargate_service_count++))
                        fi
                    done
                fi
            done
            echo ""
            echo -e "  ${BOLD}Summary:${NC} $cluster_count clusters, $fargate_service_count Fargate services"
        else
            echo -e "    ${DIM}No ECS clusters found in $AWS_REGION${NC}"
        fi
        
        echo ""
        echo -e "  ${BOLD}Fargate Task Definitions (recent 10):${NC}"
        local task_defs
        task_defs=$(aws ecs list-task-definitions --region "$AWS_REGION" --status ACTIVE --query 'taskDefinitionArns[-10:]' --output text 2>/dev/null)
        
        if [[ -n "$task_defs" ]]; then
            local td_count=0
            for td_arn in $task_defs; do
                local td_name
                td_name=$(basename "$td_arn")
                
                local compat
                compat=$(aws ecs describe-task-definition --task-definition "$td_arn" --region "$AWS_REGION" \
                    --query 'taskDefinition.compatibilities' --output text 2>/dev/null)
                
                if [[ "$compat" == *"FARGATE"* ]]; then
                    echo -e "    • ${CYAN}$td_name${NC} (Fargate compatible)"
                    ((td_count++))
                fi
            done
            
            if [[ $td_count -eq 0 ]]; then
                echo -e "    ${DIM}No Fargate-compatible task definitions found${NC}"
            fi
        else
            echo -e "    ${DIM}No task definitions found${NC}"
        fi
    fi
    
    if [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]]; then
        print_subheader "EKS Resources"
        
        echo -e "  ${BOLD}EKS Clusters:${NC}"
        local eks_clusters
        eks_clusters=$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters[*]' --output text 2>/dev/null)
        
        if [[ -n "$eks_clusters" ]]; then
            for cluster_name in $eks_clusters; do
                local cluster_info
                cluster_info=$(aws eks describe-cluster --name "$cluster_name" --region "$AWS_REGION" \
                    --query 'cluster.{status:status,version:version}' --output json 2>/dev/null)
                
                local status version
                status=$(echo "$cluster_info" | jq -r '.status')
                version=$(echo "$cluster_info" | jq -r '.version')
                
                echo -e "    • ${GREEN}$cluster_name${NC}"
                echo -e "      Status: $status | Version: $version"
                
                local fargate_profiles
                fargate_profiles=$(aws eks list-fargate-profiles --cluster-name "$cluster_name" --region "$AWS_REGION" \
                    --query 'fargateProfileNames[*]' --output text 2>/dev/null)
                
                if [[ -n "$fargate_profiles" ]]; then
                    echo -e "      Fargate Profiles: ${CYAN}$fargate_profiles${NC}"
                fi
                
                if command -v kubectl &> /dev/null; then
                    local current_context
                    current_context=$(kubectl config current-context 2>/dev/null)
                    
                    if [[ "$current_context" == *"$cluster_name"* ]]; then
                        local node_count
                        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
                        echo -e "      Nodes: $node_count ${YELLOW}← Will be protected${NC}"
                    fi
                fi
            done
        else
            echo -e "    ${DIM}No EKS clusters found in $AWS_REGION${NC}"
        fi
    fi
    
    print_subheader "ECR Repositories"
    
    local ecr_repos
    ecr_repos=$(aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories[*].repositoryName' --output text 2>/dev/null | head -10)
    
    if [[ -n "$ecr_repos" ]]; then
        echo -e "  ${BOLD}Existing Repositories:${NC}"
        for repo in $ecr_repos; do
            if [[ "$repo" == *"falcon"* ]]; then
                echo -e "    • ${GREEN}$repo${NC} (Falcon-related)"
            else
                echo -e "    • $repo"
            fi
        done
    else
        echo -e "  ${DIM}No ECR repositories found${NC}"
    fi
    
    echo ""
    set_checkpoint "resource_discovery"
    
    if ! prompt_confirm "Continue with deployment?"; then
        print_info "Deployment cancelled by user"
        exit 0
    fi
}

#===============================================================================
# VALIDATION
#===============================================================================
validate_credentials() {
    print_header "Validating Credentials"
    
    if check_checkpoint "credentials_validated" && ! $FORCE_RESTART; then
        print_success "Credentials previously validated"
        return 0
    fi
    
    print_info "Validating CrowdStrike API credentials..."
    
    local cs_cloud
    case "$FALCON_CLOUD" in
        us-1) cs_cloud="api.crowdstrike.com" ;;
        us-2) cs_cloud="api.us-2.crowdstrike.com" ;;
        eu-1) cs_cloud="api.eu-1.crowdstrike.com" ;;
        us-gov-1) cs_cloud="api.laggar.gcw.crowdstrike.com" ;;
        us-gov-2) cs_cloud="api.us-gov-2.crowdstrike.mil" ;;
        *) die "Unknown Falcon cloud: $FALCON_CLOUD" ;;
    esac
    
    local response
    response=$(curl -s -X POST "https://${cs_cloud}/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${FALCON_CLIENT_ID}&client_secret=${FALCON_CLIENT_SECRET}" \
        --connect-timeout 10)
    
    local token
    token=$(echo "$response" | jq -r '.access_token // empty')
    
    if [[ -z "$token" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        die "Failed to authenticate with CrowdStrike API: $error_msg"
    fi
    
    print_success "CrowdStrike API credentials valid"
    
    print_info "Validating AWS credentials..."
    
    local aws_identity
    aws_identity=$(aws sts get-caller-identity --output json 2>/dev/null) || die "AWS credentials invalid or expired"
    
    local aws_account
    aws_account=$(echo "$aws_identity" | jq -r '.Account')
    
    print_success "AWS credentials valid (Account: $aws_account)"
    
    print_info "Checking AWS permissions..."
    
    local permission_errors=()
    
    if ! aws ecr describe-repositories --region "$AWS_REGION" &> /dev/null; then
        permission_errors+=("ECR: describe-repositories")
    fi
    
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        if ! aws ecs list-clusters --region "$AWS_REGION" &> /dev/null; then
            permission_errors+=("ECS: list-clusters")
        fi
    fi
    
    if [[ ${#permission_errors[@]} -gt 0 ]]; then
        print_warning "Some AWS permissions may be missing:"
        for err in "${permission_errors[@]}"; do
            echo "    - $err"
        done
        
        if ! prompt_confirm "Continue anyway?"; then
            die "Deployment cancelled due to permission issues"
        fi
    else
        print_success "AWS permissions verified"
    fi
    
    set_checkpoint "credentials_validated"
}

#===============================================================================
# DRY RUN SIMULATION
#===============================================================================
perform_dry_run() {
    print_header "Dry Run - Simulating Deployment"
    
    echo -e "${MAGENTA}The following actions would be performed:${NC}"
    echo ""
    
    local step=1
    local aws_account_id
    aws_account_id=$(aws sts get-caller-identity --query 'Account' --output text)
    
    echo -e "${BOLD}[$step]${NC} Pull Falcon sensor image from CrowdStrike registry"
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        echo -e "    ${DIM}Image type: falcon-container${NC}"
    fi
    if [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]]; then
        echo -e "    ${DIM}Image type: falcon-sensor${NC}"
    fi
    ((step++))
    
    echo ""
    echo -e "${BOLD}[$step]${NC} Create ECR repository (if not exists)"
    echo -e "    ${DIM}Repository: $ECR_REPO_NAME${NC}"
    ((step++))
    
    echo ""
    echo -e "${BOLD}[$step]${NC} Push sensor image to ECR"
    echo -e "    ${DIM}Target: ${aws_account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:latest${NC}"
    ((step++))
    
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        echo ""
        echo -e "${BOLD}[$step]${NC} Patch ECS task definition with Falcon sensor"
        echo -e "    ${DIM}Adds: crowdstrike-falcon-init-container${NC}"
        echo -e "    ${DIM}Adds: SYS_PTRACE capability to all containers${NC}"
        echo -e "    ${DIM}Adds: CrowdStrike volumes and mount points${NC}"
        echo -e "    ${DIM}Modifies: Container entrypoints to load sensor first${NC}"
        ((step++))
        
        echo ""
        echo -e "${BOLD}[$step]${NC} Register new task definition revision"
        ((step++))
        
        echo ""
        echo -e "${BOLD}[$step]${NC} Update ECS service (if specified)"
        echo -e "    ${DIM}Forces new deployment with updated task definition${NC}"
        ((step++))
    fi
    
    if [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]]; then
        echo ""
        echo -e "${BOLD}[$step]${NC} Add CrowdStrike Helm repository"
        echo -e "    ${DIM}Repository: https://crowdstrike.github.io/falcon-helm${NC}"
        ((step++))
        
        echo ""
        echo -e "${BOLD}[$step]${NC} Create Kubernetes namespace"
        echo -e "    ${DIM}Namespace: $HELM_NAMESPACE${NC}"
        ((step++))
        
        echo ""
        echo -e "${BOLD}[$step]${NC} Deploy Falcon sensor via Helm"
        echo -e "    ${DIM}Release: $HELM_RELEASE_NAME${NC}"
        echo -e "    ${DIM}Chart: crowdstrike/falcon-sensor${NC}"
        echo -e "    ${DIM}Creates: DaemonSet on all nodes${NC}"
        ((step++))
        
        echo ""
        echo -e "${BOLD}[$step]${NC} Verify DaemonSet deployment"
        echo -e "    ${DIM}Wait for all pods to be ready${NC}"
        ((step++))
    fi
    
    echo ""
    echo -e "${BOLD}[$step]${NC} Verify sensor connectivity"
    echo -e "    ${DIM}Check sensor AID assignment${NC}"
    echo -e "    ${DIM}Verify CrowdStrike cloud connection${NC}"
    ((step++))
    
    echo ""
    echo -e "${BOLD}[$step]${NC} Generate deployment summary and test report"
    
    echo ""
    print_subheader "Resources That Would Be Created"
    
    echo "  • ECR Repository: $ECR_REPO_NAME"
    echo "  • Docker Image: falcon-sensor:latest"
    
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        echo "  • ECS Task Definition: (new revision with Falcon sensor)"
    fi
    
    if [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]]; then
        echo "  • Kubernetes Namespace: $HELM_NAMESPACE"
        echo "  • Helm Release: $HELM_RELEASE_NAME"
        echo "  • DaemonSet: falcon-sensor (one pod per node)"
        echo "  • ServiceAccount: falcon-sensor"
        echo "  • ConfigMap: falcon-sensor configuration"
    fi
    
    echo ""
    print_subheader "Rollback Plan"
    echo "  If deployment fails, the following cleanup actions would be performed:"
    echo ""
    
    if [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]]; then
        echo "  1. Uninstall Helm release: $HELM_RELEASE_NAME"
        echo "  2. Delete namespace: $HELM_NAMESPACE (if created by this script)"
    fi
    
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        echo "  • Deregister newly created task definition revision"
    fi
    
    echo "  • Remove pushed Docker images from ECR (optional)"
    
    echo ""
    
    if prompt_confirm "Proceed with actual deployment?"; then
        return 0
    else
        print_info "Deployment cancelled. No changes were made."
        exit 0
    fi
}

#===============================================================================
# DEPLOYMENT FUNCTIONS
#===============================================================================
pull_falcon_sensor() {
    local sensor_type="${1:-falcon-container}"
    local platform="${2:-x86_64}"
    
    print_info "Pulling Falcon sensor image (type: $sensor_type, platform: $platform)..."
    
    if $DRY_RUN; then
        print_dry_run "Would pull Falcon $sensor_type image"
        echo "crowdstrike/falcon-$sensor_type:latest"
        return 0
    fi
    
    export FALCON_CLIENT_ID
    export FALCON_CLIENT_SECRET
    export FALCON_CLOUD
    
    local latest_sensor
    latest_sensor=$(bash <(curl -sL https://github.com/CrowdStrike/falcon-scripts/releases/latest/download/falcon-container-sensor-pull.sh) \
        -t "$sensor_type" \
        --platform "$platform" \
        2>&1 | tail -1) || die "Failed to pull Falcon sensor image"
    
    [[ -z "$latest_sensor" ]] && die "Failed to determine latest sensor image"
    
    print_success "Pulled sensor image: $latest_sensor"
    echo "$latest_sensor"
}

push_to_ecr() {
    local source_image="$1"
    local repo_name="$2"
    local tag="${3:-latest}"
    
    local aws_account_id
    aws_account_id=$(aws sts get-caller-identity --query 'Account' --output text)
    local ecr_uri="${aws_account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com/${repo_name}"
    
    if $DRY_RUN; then
        print_dry_run "Would push image to ${ecr_uri}:${tag}"
        echo "${ecr_uri}:${tag}"
        return 0
    fi
    
    print_info "Ensuring ECR repository exists..."
    if ! aws ecr describe-repositories --repository-names "$repo_name" --region "$AWS_REGION" &> /dev/null; then
        print_info "Creating ECR repository: $repo_name"
        aws ecr create-repository --repository-name "$repo_name" --region "$AWS_REGION" > /dev/null || \
            die "Failed to create ECR repository"
        add_rollback_action "ecr_repository" "$repo_name" "aws ecr delete-repository --repository-name $repo_name --region $AWS_REGION --force"
        add_created_resource "ecr_repository" "$repo_name"
    fi
    
    print_info "Authenticating with ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "${aws_account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com" > /dev/null || \
        die "Failed to authenticate with ECR"
    
    print_info "Tagging image..."
    docker tag "$source_image" "${ecr_uri}:${tag}" || die "Failed to tag image"
    
    print_info "Pushing to ECR..."
    docker push "${ecr_uri}:${tag}" || die "Failed to push image"
    
    add_created_resource "ecr_image" "${ecr_uri}:${tag}"
    print_success "Image pushed to: ${ecr_uri}:${tag}"
    echo "${ecr_uri}:${tag}"
}

deploy_ecs_fargate() {
    local task_def_file="$1"
    local cluster_name="${2:-}"
    local service_name="${3:-}"
    
    print_header "Deploying to ECS Fargate"

    print_warning "Ensure firewall rules allow traffic to the Mutating Webhook on port 4433."
    print_info "The Falcon Container sensor communicates via the Mutating Webhook. Blocked traffic will cause context deadline exceeded errors."
    echo ""

    local total_steps=6
    
    # Step 1: Pull sensor image
    print_step 1 $total_steps "Pulling Falcon Container Sensor"
    
    if check_checkpoint "ecs_sensor_pulled" && ! $FORCE_RESTART; then
        print_info "Sensor already pulled (resuming from checkpoint)"
        local sensor_image
        sensor_image=$(load_variable "ecs_sensor_image")
    else
        local sensor_image
        sensor_image=$(pull_falcon_sensor "falcon-container" "$SENSOR_PLATFORM")
        save_variable "ecs_sensor_image" "$sensor_image"
        set_checkpoint "ecs_sensor_pulled"
    fi
    
    # Step 2: Push to ECR
    print_step 2 $total_steps "Pushing to ECR"
    
    if check_checkpoint "ecs_image_pushed" && ! $FORCE_RESTART; then
        print_info "Image already pushed (resuming from checkpoint)"
        local ecr_image
        ecr_image=$(load_variable "ecs_ecr_image")
    else
        local ecr_image
        ecr_image=$(push_to_ecr "$sensor_image" "$ECR_REPO_NAME" "latest")
        save_variable "ecs_ecr_image" "$ecr_image"
        set_checkpoint "ecs_image_pushed"
    fi
    
    # Step 3: Generate pull token
    print_step 3 $total_steps "Generating ECR Pull Token"
    
    if $DRY_RUN; then
        print_dry_run "Would generate ECR pull token"
    else
        local aws_account_id
        aws_account_id=$(aws sts get-caller-identity --query 'Account' --output text)
        local ecr_endpoint="${aws_account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        
        IMAGE_PULL_TOKEN=$(echo "{\"auths\":{\"${ecr_endpoint}\":{\"auth\":\"$(echo "AWS:$(aws ecr get-login-password --region "$AWS_REGION")" | base64 -w 0)\"}}}" | base64 -w 0)
        print_success "Pull token generated"
    fi
    set_checkpoint "ecs_pull_token"
    
    # Step 4: Patch task definition
    print_step 4 $total_steps "Patching Task Definition"
    
    if [[ ! -f "$task_def_file" ]]; then
        die "Task definition file not found: $task_def_file"
    fi
    
    local patched_file
    patched_file="patched-$(basename "$task_def_file")"
    
    if $DRY_RUN; then
        print_dry_run "Would patch task definition: $task_def_file"
        print_dry_run "Output file: $patched_file"
    else
        local task_def_dir
        task_def_dir=$(dirname "$(realpath "$task_def_file")")
        local task_def_basename
        task_def_basename=$(basename "$task_def_file")
        
        print_info "Running patching utility..."
        docker run -v "${task_def_dir}:/var/run/spec" \
            --rm "$ecr_image" \
            -cid "$FALCON_CID" \
            -image "$ecr_image" \
            -pulltoken "$IMAGE_PULL_TOKEN" \
            -ecs-spec-file "/var/run/spec/${task_def_basename}" > "$patched_file" || \
            die "Failed to patch task definition"
        
        # Validate the patched file
        if ! jq empty "$patched_file" 2>/dev/null; then
            die "Patched task definition is not valid JSON"
        fi
        
        print_success "Patched task definition saved to: $patched_file"
    fi
    set_checkpoint "ecs_task_patched"
    
    # Step 5: Register task definition
    print_step 5 $total_steps "Registering Task Definition"
    
    if $DRY_RUN; then
        print_dry_run "Would register task definition from: $patched_file"
        TASK_DEF_ARN="arn:aws:ecs:${AWS_REGION}:123456789:task-definition/sample:1"
    else
        local result
        result=$(aws ecs register-task-definition \
            --cli-input-json "file://${patched_file}" \
            --region "$AWS_REGION") || die "Failed to register task definition"
        
        TASK_DEF_ARN=$(echo "$result" | jq -r '.taskDefinition.taskDefinitionArn')
        local family revision
        family=$(echo "$result" | jq -r '.taskDefinition.family')
        revision=$(echo "$result" | jq -r '.taskDefinition.revision')
        
        save_variable "task_def_arn" "$TASK_DEF_ARN"
        add_rollback_action "task_definition" "$TASK_DEF_ARN" "aws ecs deregister-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION"
        add_created_resource "task_definition" "$TASK_DEF_ARN"
        
        print_success "Task definition registered: ${family}:${revision}"
    fi
    set_checkpoint "ecs_task_registered"
    
    # Step 6: Update service (if specified)
    print_step 6 $total_steps "Updating ECS Service"
    
    if [[ -n "$cluster_name" ]] && [[ -n "$service_name" ]]; then
        if $DRY_RUN; then
            print_dry_run "Would update service $service_name in cluster $cluster_name"
        else
            aws ecs update-service \
                --cluster "$cluster_name" \
                --service "$service_name" \
                --task-definition "$TASK_DEF_ARN" \
                --force-new-deployment \
                --region "$AWS_REGION" > /dev/null || die "Failed to update ECS service"
            
            print_success "Service updated: $service_name"
            
            # Wait for service stability
            print_info "Waiting for service to stabilize..."
            aws ecs wait services-stable \
                --cluster "$cluster_name" \
                --services "$service_name" \
                --region "$AWS_REGION" 2>/dev/null || print_warning "Service may still be deploying"
        fi
    else
        print_info "No cluster/service specified. To update manually, run:"
        echo "    aws ecs update-service --cluster <CLUSTER> --service <SERVICE> \\"
        echo "        --task-definition $TASK_DEF_ARN --force-new-deployment"
    fi
    set_checkpoint "ecs_service_updated"
    
    update_state ".status" "completed"
    set_checkpoint "ecs_deployment_complete"
}

deploy_eks() {
    print_header "Deploying to EKS"
    
    if ! command -v helm &> /dev/null; then
        die "Helm is required for EKS deployment but not installed"
    fi
    
    if ! command -v kubectl &> /dev/null; then
        die "kubectl is required for EKS deployment but not installed"
    fi
    
    local total_steps=7
    
    # Step 1: Pull sensor image
    print_step 1 $total_steps "Pulling Falcon Node Sensor"
    
    if check_checkpoint "eks_sensor_pulled" && ! $FORCE_RESTART; then
        print_info "Sensor already pulled (resuming from checkpoint)"
        local sensor_image
        sensor_image=$(load_variable "eks_sensor_image")
    else
        local sensor_image
        sensor_image=$(pull_falcon_sensor "falcon-sensor" "$SENSOR_PLATFORM")
        save_variable "eks_sensor_image" "$sensor_image"
        set_checkpoint "eks_sensor_pulled"
    fi
    
    # Step 2: Push to ECR
    print_step 2 $total_steps "Pushing to ECR"
    
    if check_checkpoint "eks_image_pushed" && ! $FORCE_RESTART; then
        print_info "Image already pushed (resuming from checkpoint)"
        local ecr_image
        ecr_image=$(load_variable "eks_ecr_image")
    else
        local ecr_image
        ecr_image=$(push_to_ecr "$sensor_image" "falcon-sensor/falcon-node-sensor" "latest")
        save_variable "eks_ecr_image" "$ecr_image"
        set_checkpoint "eks_image_pushed"
    fi
    
    # Step 3: Setup Helm repo
    print_step 3 $total_steps "Setting Up Helm Repository"
    
    if $DRY_RUN; then
        print_dry_run "Would add CrowdStrike Helm repository"
    else
        helm repo add crowdstrike https://crowdstrike.github.io/falcon-helm 2>/dev/null || true
        helm repo update crowdstrike > /dev/null || die "Failed to update Helm repository"
        print_success "Helm repository configured"
    fi
    set_checkpoint "eks_helm_repo"
    
    # Step 4: Create namespace
    print_step 4 $total_steps "Creating Kubernetes Namespace"
    
    if $DRY_RUN; then
        print_dry_run "Would create namespace: $HELM_NAMESPACE"
    else
        if ! kubectl get namespace "$HELM_NAMESPACE" &> /dev/null; then
            kubectl create namespace "$HELM_NAMESPACE" || die "Failed to create namespace"
            add_rollback_action "namespace" "$HELM_NAMESPACE" "kubectl delete namespace $HELM_NAMESPACE"
            add_created_resource "namespace" "$HELM_NAMESPACE"
            print_success "Namespace created: $HELM_NAMESPACE"
        else
            print_info "Namespace already exists: $HELM_NAMESPACE"
        fi

        # Apply Pod Security Admission labels (required for privileged sensor workloads)
        print_info "Applying Pod Security Admission labels to namespace..."
        kubectl label namespace "$HELM_NAMESPACE" \
            "pod-security.kubernetes.io/enforce=privileged" \
            "pod-security.kubernetes.io/audit=privileged" \
            "pod-security.kubernetes.io/warn=privileged" \
            --overwrite || print_warning "Failed to apply PSA labels to namespace"
    fi
    set_checkpoint "eks_namespace"
    
    # Step 5: Generate values file
    print_step 5 $total_steps "Generating Helm Values"
    
    local values_file
    values_file="${STATE_DIR}/falcon-values-$(date +%Y%m%d-%H%M%S).yaml"
    
    local image_repo="${ecr_image%:*}"
    local image_tag="${ecr_image##*:}"
    
    cat > "$values_file" << EOF
# CrowdStrike Falcon Sensor Helm Values
# Generated: $(date)

falcon:
  cid: "${FALCON_CID}"
  cloud: "${FALCON_CLOUD}"
$(if [[ -n "${SENSOR_TAGS:-}" ]]; then
  echo "  tags:"
  IFS=',' read -ra TAGS <<< "$SENSOR_TAGS"
  for tag in "${TAGS[@]}"; do
    echo "    - \"${tag}\""
  done
fi)

node:
  enabled: true
  backend: bpf
  
  image:
    repository: "${image_repo}"
    tag: "${image_tag}"
    pullPolicy: Always
  
  daemonset:
    tolerations:
      - operator: Exists
        effect: NoSchedule
      - operator: Exists
        effect: NoExecute
$(if [[ "$SENSOR_PLATFORM" == "aarch64" ]]; then
cat << 'AFFINITY'

  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/arch
                operator: In
                values:
                  - arm64
AFFINITY
fi)

  resources:
    limits:
      cpu: 750m
      memory: 256Mi
    requests:
      cpu: 500m
      memory: 256Mi

container:
  enabled: false
EOF
    
    save_variable "eks_values_file" "$values_file"
    print_success "Values file generated: $values_file"
    set_checkpoint "eks_values"
    
    # Step 6: Deploy via Helm
    print_step 6 $total_steps "Deploying Falcon Sensor"
    
    if $DRY_RUN; then
        print_dry_run "Would deploy Helm chart with values from: $values_file"
        echo ""
        echo "Helm command that would be executed:"
        echo "  helm upgrade --install $HELM_RELEASE_NAME crowdstrike/falcon-sensor \\"
        echo "    --namespace $HELM_NAMESPACE \\"
        echo "    -f $values_file \\"
        echo "    --wait --timeout 10m"
    else
        if helm status "$HELM_RELEASE_NAME" -n "$HELM_NAMESPACE" &> /dev/null; then
            print_info "Upgrading existing release..."
            helm upgrade "$HELM_RELEASE_NAME" crowdstrike/falcon-sensor \
                --namespace "$HELM_NAMESPACE" \
                -f "$values_file" \
                --wait \
                --timeout 10m || die "Helm upgrade failed"
        else
            print_info "Installing new release..."
            helm install "$HELM_RELEASE_NAME" crowdstrike/falcon-sensor \
                --namespace "$HELM_NAMESPACE" \
                -f "$values_file" \
                --wait \
                --timeout 10m || die "Helm install failed"
            
            add_rollback_action "helm_release" "$HELM_RELEASE_NAME" "helm uninstall $HELM_RELEASE_NAME -n $HELM_NAMESPACE"
            add_created_resource "helm_release" "$HELM_RELEASE_NAME"
        fi
        
        print_success "Falcon sensor deployed"
    fi
    set_checkpoint "eks_helm_deployed"
    
    # Step 7: Verify deployment
    print_step 7 $total_steps "Verifying Deployment"
    
    if $DRY_RUN; then
        print_dry_run "Would verify DaemonSet deployment"
    else
        print_info "Waiting for DaemonSet to be ready..."
        
        local retries=30
        local ready=false
        
        while [[ $retries -gt 0 ]]; do
            local desired ready_count
            desired=$(kubectl get daemonset -n "$HELM_NAMESPACE" -l app=falcon-sensor -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
            ready_count=$(kubectl get daemonset -n "$HELM_NAMESPACE" -l app=falcon-sensor -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
            
            if [[ "$desired" -gt 0 ]] && [[ "$ready_count" -eq "$desired" ]]; then
                ready=true
                break
            fi
            
            echo -ne "\r  Pods ready: ${ready_count}/${desired} (waiting...)"
            sleep 5
            ((retries--))
        done
        
        echo ""
        
        if $ready; then
            print_success "All sensor pods are ready (${ready_count}/${desired})"
        else
            print_warning "Some pods may still be starting"
        fi
    fi
    set_checkpoint "eks_verified"
    
    update_state ".status" "completed"
    set_checkpoint "eks_deployment_complete"
}

#===============================================================================
# TESTING AND VERIFICATION
#===============================================================================
run_tests() {
    print_header "Running Deployment Tests"
    
    local tests_total=0
    local tests_passed=0
    local tests_failed=0
    local tests_skipped=0
    declare -a test_results
    
    run_test() {
        local test_name="$1"
        local test_command="$2"
        
        ((tests_total++))
        printf "  %-50s" "$test_name"
        
        if $DRY_RUN; then
            echo -e "${MAGENTA}SKIP${NC} (dry-run)"
            test_results+=("$test_name|SKIP|Dry-run mode")
            ((tests_skipped++))
            return 0
        fi
        
        local output
        if output=$(eval "$test_command" 2>&1); then
            echo -e "${GREEN}PASS${NC}"
            ((tests_passed++))
            test_results+=("$test_name|PASS|$output")
            return 0
        else
            echo -e "${RED}FAIL${NC}"
            ((tests_failed++))
            test_results+=("$test_name|FAIL|$output")
            return 1
        fi
    }
    
    print_subheader "Infrastructure Tests"
    
    run_test "ECR repository exists" \
        "aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $AWS_REGION"
    
    run_test "Sensor image exists in ECR" \
        "aws ecr describe-images --repository-name $ECR_REPO_NAME --region $AWS_REGION --query 'imageDetails[0].imageTags' --output text 2>/dev/null | grep -q latest"
    
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        print_subheader "ECS Fargate Tests"
        
        local task_def_arn_saved
        task_def_arn_saved=$(load_variable "task_def_arn")
        
        if [[ -n "$task_def_arn_saved" ]]; then
            run_test "Task definition registered" \
                "aws ecs describe-task-definition --task-definition $task_def_arn_saved --region $AWS_REGION"
            
            run_test "Task definition has Falcon init container" \
                "aws ecs describe-task-definition --task-definition $task_def_arn_saved --region $AWS_REGION --query 'taskDefinition.containerDefinitions[*].name' --output text | grep -q crowdstrike-falcon-init-container"
            
            run_test "Task definition has SYS_PTRACE capability" \
                "aws ecs describe-task-definition --task-definition $task_def_arn_saved --region $AWS_REGION --query 'taskDefinition.containerDefinitions[*].linuxParameters.capabilities.add' --output text | grep -q SYS_PTRACE"
        fi
    fi
    
    if [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]]; then
        print_subheader "EKS Tests"
        
        run_test "Kubernetes namespace exists" \
            "kubectl get namespace $HELM_NAMESPACE"
        
        run_test "Helm release deployed" \
            "helm status $HELM_RELEASE_NAME -n $HELM_NAMESPACE"
        
        run_test "DaemonSet created" \
            "kubectl get daemonset -n $HELM_NAMESPACE -l app=falcon-sensor"
        
        run_test "Sensor pods running" \
            "kubectl get pods -n $HELM_NAMESPACE -l app=falcon-sensor --field-selector=status.phase=Running --no-headers | grep -q falcon"
        
        run_test "All DaemonSet pods ready" \
            "test \$(kubectl get daemonset -n $HELM_NAMESPACE -l app=falcon-sensor -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo 0) -eq \$(kubectl get daemonset -n $HELM_NAMESPACE -l app=falcon-sensor -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo 1)"
    fi
    
    print_subheader "Connectivity Tests"
    
    local cs_cloud
    case "$FALCON_CLOUD" in
        us-1) cs_cloud="api.crowdstrike.com" ;;
        us-2) cs_cloud="api.us-2.crowdstrike.com" ;;
        eu-1) cs_cloud="api.eu-1.crowdstrike.com" ;;
        us-gov-1) cs_cloud="api.laggar.gcw.crowdstrike.com" ;;
        us-gov-2) cs_cloud="api.us-gov-2.crowdstrike.mil" ;;
    esac
    
    run_test "CrowdStrike API reachable" \
        "curl -s --connect-timeout 5 https://${cs_cloud}/oauth2/token -o /dev/null"
    
    run_test "AWS STS accessible" \
        "aws sts get-caller-identity"
    
    echo ""
    print_subheader "Test Summary"
    echo ""
    echo "  Total Tests:  $tests_total"
    echo -e "  ${GREEN}Passed:${NC}       $tests_passed"
    echo -e "  ${RED}Failed:${NC}       $tests_failed"
    echo -e "  ${MAGENTA}Skipped:${NC}      $tests_skipped"
    
    if [[ $tests_failed -gt 0 ]]; then
        echo ""
        print_subheader "Failed Test Details"
        for result in "${test_results[@]}"; do
            IFS='|' read -r name status output <<< "$result"
            if [[ "$status" == "FAIL" ]]; then
                echo -e "  ${RED}x${NC} $name"
            fi
        done
    fi
    
    [[ $tests_failed -eq 0 ]]
}

#===============================================================================
# DEPLOYMENT SUMMARY
#===============================================================================
generate_summary() {
    print_header "Deployment Summary"
    
    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    local start_time
    start_time=$(jq -r '.started_at // "unknown"' "$STATE_FILE" 2>/dev/null)
    
    local status
    status=$(jq -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null)
    
    echo -e "  ${BOLD}Deployment Information${NC}"
    echo "  ---------------------------------------------------------------"
    echo "  Script Version:     $SCRIPT_VERSION"
    echo "  Start Time:         $start_time"
    echo "  End Time:           $end_time"
    echo "  Deployment Type:    $DEPLOYMENT_TYPE"
    echo "  Mode:               $([ "$DRY_RUN" == "true" ] && echo "Dry Run" || echo "Live")"
    echo "  Status:             $status"
    echo ""
    
    echo -e "  ${BOLD}CrowdStrike Configuration${NC}"
    echo "  ---------------------------------------------------------------"
    echo "  Falcon Cloud:       $FALCON_CLOUD"
    echo "  Falcon CID:         ${FALCON_CID:0:20}..."
    [[ -n "${SENSOR_TAGS:-}" ]] && echo "  Sensor Tags:        $SENSOR_TAGS"
    echo ""
    
    echo -e "  ${BOLD}AWS Configuration${NC}"
    echo "  ---------------------------------------------------------------"
    echo "  Region:             $AWS_REGION"
    echo "  Account ID:         $(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)"
    echo "  ECR Repository:     $ECR_REPO_NAME"
    echo ""
    
    echo -e "  ${BOLD}Created Resources${NC}"
    echo "  ---------------------------------------------------------------"
    
    if [[ -f "$STATE_FILE" ]]; then
        jq -r '.created_resources[]? | "  - \(.type): \(.id)"' "$STATE_FILE" 2>/dev/null || echo "  (none)"
    fi
    
    echo ""
    echo -e "  ${BOLD}Next Steps${NC}"
    echo "  ---------------------------------------------------------------"
    echo "  1. Verify sensors appear in Falcon Console:"
    echo "     https://falcon.crowdstrike.com/hosts/hosts"
    echo ""
    
    if [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]]; then
        echo "  2. Check EKS sensor logs:"
        echo "     kubectl logs -n $HELM_NAMESPACE -l app=falcon-sensor"
        echo ""
    fi
    
    if [[ "$DEPLOYMENT_TYPE" == *"ECS"* ]]; then
        echo "  2. Check ECS task sensor status:"
        echo "     aws ecs execute-command --cluster <CLUSTER> --task <TASK_ID> \\"
        echo "       --container <CONTAINER> --command 'ps -aef | grep falcon'"
        echo ""
    fi
    
    echo "  3. Log file location:"
    echo "     $LOG_FILE"
    echo ""
    
    if ! $DRY_RUN; then
        if [[ "$status" == "completed" ]]; then
            echo -e "  ${GREEN}========================================${NC}"
            echo -e "  ${GREEN}  DEPLOYMENT COMPLETED SUCCESSFULLY     ${NC}"
            echo -e "  ${GREEN}========================================${NC}"
        else
            echo -e "  ${RED}========================================${NC}"
            echo -e "  ${RED}  DEPLOYMENT COMPLETED WITH ISSUES      ${NC}"
            echo -e "  ${RED}========================================${NC}"
        fi
    else
        echo -e "  ${MAGENTA}========================================${NC}"
        echo -e "  ${MAGENTA}  DRY RUN COMPLETED - NO CHANGES MADE   ${NC}"
        echo -e "  ${MAGENTA}========================================${NC}"
    fi
    
    echo ""
}

#===============================================================================
# MULTI-ACCOUNT DEPLOYMENT FUNCTIONS
#===============================================================================
enumerate_org_accounts() {
    print_info "Enumerating all accounts in the AWS Organization..."

    local accounts
    accounts=$(aws organizations list-accounts --query 'Accounts[?Status==`ACTIVE`].Id' --output text 2>/dev/null) || \
        die "Failed to list organization accounts. Ensure you have organizations:ListAccounts permission."

    TARGET_ACCOUNTS=()
    for acct in $accounts; do
        TARGET_ACCOUNTS+=("$acct")
    done

    print_success "Found ${#TARGET_ACCOUNTS[@]} active accounts in the organization"
}

enumerate_ou_accounts() {
    print_info "Enumerating accounts for specified OUs..."

    TARGET_ACCOUNTS=()
    IFS=',' read -ra ou_list <<< "$OU_IDS"
    for ou_id in "${ou_list[@]}"; do
        ou_id=$(echo "$ou_id" | tr -d ' ')
        print_info "Processing OU: $ou_id"
        _enumerate_ou_recursive "$ou_id"
    done

    # Deduplicate
    local -A seen
    local unique=()
    for acct in "${TARGET_ACCOUNTS[@]}"; do
        if [[ -z "${seen[$acct]:-}" ]]; then
            seen[$acct]=1
            unique+=("$acct")
        fi
    done
    TARGET_ACCOUNTS=("${unique[@]}")

    print_success "Found ${#TARGET_ACCOUNTS[@]} unique active accounts across specified OUs"
}

_enumerate_ou_recursive() {
    local parent_id="$1"

    # Get direct accounts
    local accounts
    accounts=$(aws organizations list-accounts-for-parent --parent-id "$parent_id" \
        --query 'Accounts[?Status==`ACTIVE`].Id' --output text 2>/dev/null) || {
        print_warning "Failed to list accounts for parent: $parent_id"
        return
    }

    for acct in $accounts; do
        TARGET_ACCOUNTS+=("$acct")
    done

    # Get child OUs and recurse
    local child_ous
    child_ous=$(aws organizations list-children --parent-id "$parent_id" --child-type ORGANIZATIONAL_UNIT \
        --query 'Children[*].Id' --output text 2>/dev/null) || return

    for child_ou in $child_ous; do
        [[ "$child_ou" == "None" ]] && continue
        _enumerate_ou_recursive "$child_ou"
    done
}

assume_account_role() {
    local account_id="$1"
    local role_name="$2"
    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

    print_info "Assuming role ${role_name} in account ${account_id}..."

    local creds
    creds=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "falcon-deploy-${account_id}" \
        --duration-seconds 3600 \
        --output json 2>/dev/null) || {
        print_error "Failed to assume role ${role_arn}"
        return 1
    }

    export AWS_ACCESS_KEY_ID
    AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY
    AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN
    AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')

    print_success "Assumed role in account ${account_id}"
    return 0
}

clear_assumed_role() {
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
}

init_multi_account_state() {
    local hub_account="$1"

    local state_file="${STATE_DIR}/multi-account-state.json"
    if [[ -f "$state_file" ]] && [[ "$FORCE_RESTART" != "true" ]]; then
        print_info "Found existing multi-account state"
        return 0
    fi

    cat > "$state_file" << EOF
{
    "version": "${SCRIPT_VERSION}",
    "deploy_mode": "${DEPLOY_MODE}",
    "hub_account": "${hub_account}",
    "cross_account_role": "${CROSS_ACCOUNT_ROLE}",
    "accounts": {}
}
EOF
    print_success "Initialized multi-account state"
}

update_account_state() {
    local account_id="$1"
    local status="$2"
    local error="${3:-null}"

    local state_file="${STATE_DIR}/multi-account-state.json"
    if [[ -f "$state_file" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        if [[ "$error" == "null" ]]; then
            jq ".accounts[\"$account_id\"] = {\"status\": \"$status\", \"error\": null}" "$state_file" > "$tmp_file" && mv "$tmp_file" "$state_file"
        else
            local escaped_error
            escaped_error=$(echo "$error" | sed 's/\\/\\\\/g; s/"/\\"/g')
            jq ".accounts[\"$account_id\"] = {\"status\": \"$status\", \"error\": \"$escaped_error\"}" "$state_file" > "$tmp_file" && mv "$tmp_file" "$state_file"
        fi
    fi
}

deploy_to_account() {
    local account_id="$1"
    local hub_ecr_image="$2"

    print_header "Deploying to Account: ${account_id}"

    # Check if already successfully deployed (resume support)
    local state_file="${STATE_DIR}/multi-account-state.json"
    if [[ -f "$state_file" ]] && [[ "$FORCE_RESTART" != "true" ]]; then
        local prev_status
        prev_status=$(jq -r ".accounts[\"$account_id\"].status // empty" "$state_file" 2>/dev/null)
        if [[ "$prev_status" == "success" ]]; then
            print_info "Account ${account_id} previously deployed successfully, skipping (use --force to re-deploy)"
            ACCOUNT_RESULTS[$account_id]="skipped"
            return 0
        fi
    fi

    update_account_state "$account_id" "in_progress"

    # Assume role into target account
    if ! assume_account_role "$account_id" "$CROSS_ACCOUNT_ROLE"; then
        update_account_state "$account_id" "failed" "Role assumption failed"
        ACCOUNT_RESULTS[$account_id]="failed"
        if ! $CONTINUE_ON_FAILURE; then
            die "Stopping deployment: failed to assume role in account ${account_id}"
        fi
        return 1
    fi

    # Override ECR image to use hub account's image
    save_variable "ecs_ecr_image" "$hub_ecr_image"
    save_variable "eks_ecr_image" "$hub_ecr_image"

    # Per-account state file
    local original_state_file="$STATE_FILE"
    STATE_FILE="${STATE_DIR}/account-${account_id}-state.json"
    FORCE_RESTART=true
    init_state

    # Run the appropriate deployment
    local deploy_ok=true
    case "$DEPLOYMENT_TYPE" in
        *"ECS"*)
            if [[ -n "${TASK_DEF_FILE:-}" ]]; then
                deploy_ecs_fargate "$TASK_DEF_FILE" "${ECS_CLUSTER:-}" "${ECS_SERVICE:-}" || deploy_ok=false
            else
                print_warning "No task definition file specified for ECS deployment in account ${account_id}"
                deploy_ok=false
            fi
            ;;
    esac

    case "$DEPLOYMENT_TYPE" in
        *"EKS"*)
            deploy_eks || deploy_ok=false
            ;;
    esac

    # Restore state
    STATE_FILE="$original_state_file"
    clear_assumed_role

    if $deploy_ok; then
        update_account_state "$account_id" "success"
        ACCOUNT_RESULTS[$account_id]="success"
        print_success "Deployment to account ${account_id} completed"
    else
        update_account_state "$account_id" "failed" "Deployment failed"
        ACCOUNT_RESULTS[$account_id]="failed"
        if ! $CONTINUE_ON_FAILURE; then
            die "Stopping deployment: deployment failed in account ${account_id}"
        fi
        return 1
    fi

    return 0
}

deploy_multi_account() {
    print_header "Multi-Account Deployment"

    local hub_account
    hub_account=$(aws sts get-caller-identity --query 'Account' --output text) || \
        die "Failed to determine hub account ID"

    print_info "Hub (management) account: ${hub_account}"

    # Initialize multi-account state
    init_multi_account_state "$hub_account"

    # Enumerate target accounts
    case "$DEPLOY_MODE" in
        org) enumerate_org_accounts ;;
        ou)  enumerate_ou_accounts ;;
        *)   die "Invalid deploy mode for multi-account: $DEPLOY_MODE" ;;
    esac

    if [[ ${#TARGET_ACCOUNTS[@]} -eq 0 ]]; then
        die "No target accounts found"
    fi

    # Remove hub account from targets (it can be deployed separately)
    local filtered=()
    for acct in "${TARGET_ACCOUNTS[@]}"; do
        if [[ "$acct" != "$hub_account" ]]; then
            filtered+=("$acct")
        fi
    done
    TARGET_ACCOUNTS=("${filtered[@]}")

    print_info "Target accounts (excluding hub): ${#TARGET_ACCOUNTS[@]}"
    for acct in "${TARGET_ACCOUNTS[@]}"; do
        echo "  - $acct"
    done
    echo ""

    if $INTERACTIVE && ! prompt_confirm "Proceed with deployment to ${#TARGET_ACCOUNTS[@]} accounts?"; then
        print_info "Multi-account deployment cancelled"
        exit 0
    fi

    # Step 1: Pull sensor image once in hub account
    print_subheader "Pulling Sensor Image (Hub Account)"

    local sensor_type="falcon-container"
    [[ "$DEPLOYMENT_TYPE" == *"EKS"* ]] && sensor_type="falcon-sensor"

    local sensor_image
    sensor_image=$(pull_falcon_sensor "$sensor_type" "$SENSOR_PLATFORM")

    local hub_ecr_image
    hub_ecr_image=$(push_to_ecr "$sensor_image" "$ECR_REPO_NAME" "latest")

    # Step 2: Set cross-account ECR pull policy
    if ! $DRY_RUN; then
        print_subheader "Setting ECR Cross-Account Pull Policy"

        local account_arns="["
        local first=true
        for acct in "${TARGET_ACCOUNTS[@]}"; do
            if $first; then
                first=false
            else
                account_arns+=","
            fi
            account_arns+="\"arn:aws:iam::${acct}:root\""
        done
        account_arns+="]"

        local policy
        policy=$(cat <<EOFPOLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CrossAccountPull",
            "Effect": "Allow",
            "Principal": {
                "AWS": ${account_arns}
            },
            "Action": [
                "ecr:BatchGetImage",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchCheckLayerAvailability"
            ]
        }
    ]
}
EOFPOLICY
)

        aws ecr set-repository-policy \
            --repository-name "$ECR_REPO_NAME" \
            --policy-text "$policy" \
            --region "$AWS_REGION" > /dev/null 2>&1 || \
            print_warning "Failed to set ECR cross-account policy. Target accounts may not be able to pull the image."

        print_success "ECR cross-account pull policy set for ${#TARGET_ACCOUNTS[@]} accounts"
    else
        print_dry_run "Would set ECR cross-account pull policy for ${#TARGET_ACCOUNTS[@]} accounts"
    fi

    # Step 3: Deploy to each account
    print_subheader "Deploying to Target Accounts"

    local account_num=0
    for acct in "${TARGET_ACCOUNTS[@]}"; do
        ((account_num++))
        echo ""
        print_info "Account ${account_num}/${#TARGET_ACCOUNTS[@]}: ${acct}"

        if $DRY_RUN; then
            print_dry_run "Would deploy to account ${acct}"
            ACCOUNT_RESULTS[$acct]="dry-run"
            continue
        fi

        deploy_to_account "$acct" "$hub_ecr_image" || true
    done

    # Step 4: Summary
    generate_multi_account_summary
}

generate_multi_account_summary() {
    print_header "Multi-Account Deployment Summary"

    local success_count=0
    local failed_count=0
    local skipped_count=0
    local dryrun_count=0
    local failed_accounts=()

    for acct in "${!ACCOUNT_RESULTS[@]}"; do
        case "${ACCOUNT_RESULTS[$acct]}" in
            success)  ((success_count++)) ;;
            failed)   ((failed_count++)); failed_accounts+=("$acct") ;;
            skipped)  ((skipped_count++)) ;;
            dry-run)  ((dryrun_count++)) ;;
        esac
    done

    local total=${#ACCOUNT_RESULTS[@]}

    echo "  Total accounts:     $total"
    echo -e "  ${GREEN}Succeeded:${NC}          $success_count"
    echo -e "  ${RED}Failed:${NC}             $failed_count"
    echo -e "  ${YELLOW}Skipped:${NC}            $skipped_count"
    if [[ $dryrun_count -gt 0 ]]; then
        echo -e "  ${MAGENTA}Dry-run:${NC}            $dryrun_count"
    fi

    if [[ ${#failed_accounts[@]} -gt 0 ]]; then
        echo ""
        print_subheader "Failed Accounts"
        local state_file="${STATE_DIR}/multi-account-state.json"
        for acct in "${failed_accounts[@]}"; do
            local error="unknown"
            if [[ -f "$state_file" ]]; then
                error=$(jq -r ".accounts[\"$acct\"].error // \"unknown\"" "$state_file" 2>/dev/null)
            fi
            echo -e "  ${RED}x${NC} ${acct}: ${error}"
        done
    fi

    echo ""
    if [[ $failed_count -eq 0 ]] && [[ $dryrun_count -eq 0 ]]; then
        echo -e "  ${GREEN}========================================${NC}"
        echo -e "  ${GREEN}  ALL ACCOUNTS DEPLOYED SUCCESSFULLY    ${NC}"
        echo -e "  ${GREEN}========================================${NC}"
    elif [[ $dryrun_count -gt 0 ]]; then
        echo -e "  ${MAGENTA}========================================${NC}"
        echo -e "  ${MAGENTA}  DRY RUN COMPLETED - NO CHANGES MADE   ${NC}"
        echo -e "  ${MAGENTA}========================================${NC}"
    else
        echo -e "  ${YELLOW}========================================${NC}"
        echo -e "  ${YELLOW}  DEPLOYMENT COMPLETED WITH FAILURES    ${NC}"
        echo -e "  ${YELLOW}========================================${NC}"
    fi
    echo ""
}

#===============================================================================
# HELP AND MAIN
#===============================================================================
show_banner() {
    echo ""
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}     CrowdStrike Falcon Sensor Deployment Script v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}     Supports: ECS Fargate (Sidecar) | EKS (Helm DaemonSet)${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo ""
}

show_help() {
    show_banner
    cat << EOF
USAGE:
    $SCRIPT_NAME [OPTIONS] [COMMAND]

COMMANDS:
    deploy              Interactive deployment (default)
    deploy-ecs <file>   Deploy to ECS Fargate with task definition file
    deploy-eks          Deploy to EKS cluster
    deploy-org          Deploy across AWS Organization or specific OUs
    status              Show deployment status
    rollback            Rollback last deployment
    cleanup             Remove all deployed resources
    test                Run deployment verification tests
    help                Show this help message

OPTIONS:
    -d, --dry-run           Simulate deployment without making changes
    -f, --force             Force restart (ignore saved state)
    -n, --non-interactive   Run without prompts (requires env vars)
    -v, --verbose           Enable verbose output
    --org                   Deploy to all accounts in the AWS Organization
    --ou <ou-ids>           Deploy to specific OUs (comma-separated)
    --role <name>           Cross-account IAM role name (default: FalconSensorDeployRole)
    --platform <arch>       Sensor platform: x86_64 or aarch64 (default: x86_64)
    --stop-on-failure       Halt on first account failure (default: continue)
    -h, --help              Show this help message

ENVIRONMENT VARIABLES (for non-interactive mode):
    FALCON_CLIENT_ID        CrowdStrike API client ID
    FALCON_CLIENT_SECRET    CrowdStrike API client secret
    FALCON_CID              CrowdStrike customer ID (with checksum)
    FALCON_CLOUD            CrowdStrike cloud (us-1, us-2, eu-1, us-gov-1, us-gov-2)
    AWS_REGION              AWS region
    ECR_REPO_NAME           ECR repository name
    HELM_NAMESPACE          Kubernetes namespace
    HELM_RELEASE_NAME       Helm release name
    SENSOR_TAGS             Comma-separated sensor tags
    SENSOR_PLATFORM         Sensor architecture: x86_64 or aarch64

EXAMPLES:
    # Interactive deployment
    $SCRIPT_NAME deploy

    # Dry-run to preview changes
    $SCRIPT_NAME --dry-run deploy

    # Deploy to ECS with task definition
    $SCRIPT_NAME deploy-ecs ./my-task-definition.json

    # Deploy to EKS
    $SCRIPT_NAME deploy-eks

    # Deploy to all accounts in the organization
    $SCRIPT_NAME --org deploy

    # Deploy to specific OUs
    $SCRIPT_NAME --ou ou-xxxx-xxxxxxxx,ou-yyyy-yyyyyyyy deploy

    # Deploy to org with custom role and arm64
    $SCRIPT_NAME --org --role MyDeployRole --platform aarch64 deploy

    # Non-interactive org deployment
    export FALCON_CLIENT_ID="xxx" FALCON_CLIENT_SECRET="xxx" FALCON_CID="xxx-xx"
    $SCRIPT_NAME -n --org deploy

    # Non-interactive deployment
    export FALCON_CLIENT_ID="xxx" FALCON_CLIENT_SECRET="xxx" FALCON_CID="xxx-xx"
    $SCRIPT_NAME --non-interactive deploy-eks

    # Check status (includes multi-account status if applicable)
    $SCRIPT_NAME status

    # Run tests
    $SCRIPT_NAME test

EOF
}

show_status() {
    print_header "Deployment Status"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        print_info "No previous deployment found"
        return 0
    fi
    
    echo -e "  ${BOLD}State File:${NC} $STATE_FILE"
    echo ""
    
    jq -r '"  Status: \(.status // "unknown")\n  Started: \(.started_at // "unknown")\n  Last Updated: \(.last_updated // "unknown")"' "$STATE_FILE" 2>/dev/null
    
    echo ""
    echo -e "  ${BOLD}Checkpoints:${NC}"
    jq -r '.checkpoints | to_entries[] | "  - \(.key): \(.value.status)"' "$STATE_FILE" 2>/dev/null || echo "  (none)"
    
    echo ""
    echo -e "  ${BOLD}Created Resources:${NC}"
    jq -r '.created_resources[]? | "  - \(.type): \(.id)"' "$STATE_FILE" 2>/dev/null || echo "  (none)"

    local multi_state="${STATE_DIR}/multi-account-state.json"
    if [[ -f "$multi_state" ]]; then
        echo ""
        print_subheader "Multi-Account Deployment Status"

        local deploy_mode hub_account
        deploy_mode=$(jq -r '.deploy_mode // "unknown"' "$multi_state" 2>/dev/null)
        hub_account=$(jq -r '.hub_account // "unknown"' "$multi_state" 2>/dev/null)

        echo "  Deploy Mode:        $deploy_mode"
        echo "  Hub Account:        $hub_account"
        echo ""

        local total success failed
        total=$(jq '.accounts | length' "$multi_state" 2>/dev/null || echo 0)
        success=$(jq '[.accounts[] | select(.status == "success")] | length' "$multi_state" 2>/dev/null || echo 0)
        failed=$(jq '[.accounts[] | select(.status == "failed")] | length' "$multi_state" 2>/dev/null || echo 0)

        echo "  Total Accounts:     $total"
        echo -e "  ${GREEN}Succeeded:${NC}          $success"
        echo -e "  ${RED}Failed:${NC}             $failed"

        if [[ "$failed" -gt 0 ]]; then
            echo ""
            echo -e "  ${BOLD}Failed Accounts:${NC}"
            jq -r '.accounts | to_entries[] | select(.value.status == "failed") | "  - \(.key): \(.value.error // "unknown")"' "$multi_state" 2>/dev/null
        fi
    fi
}

main() {
    local command=""
    local task_def_file=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run) DRY_RUN=true; shift ;;
            -f|--force) FORCE_RESTART=true; shift ;;
            -n|--non-interactive) INTERACTIVE=false; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -h|--help) show_help; exit 0 ;;
            --org) DEPLOY_MODE="org"; shift ;;
            --ou) DEPLOY_MODE="ou"; shift; OU_IDS="$1"; shift ;;
            --role) shift; CROSS_ACCOUNT_ROLE="$1"; shift ;;
            --platform) shift; SENSOR_PLATFORM="$1"; shift ;;
            --stop-on-failure) CONTINUE_ON_FAILURE=false; shift ;;
            deploy|deploy-ecs|deploy-eks|deploy-org|status|rollback|cleanup|test|help)
                command="$1"; shift
                if [[ "$command" == "deploy-ecs" ]] && [[ $# -gt 0 ]]; then
                    task_def_file="$1"; shift
                fi
                ;;
            *) if [[ -z "$command" ]]; then command="$1"; fi; shift ;;
        esac
    done
    
    command="${command:-deploy}"
    
    init_logging
    show_banner
    
    case "$command" in
        deploy)
            init_state
            check_prerequisites || exit 1
            collect_configuration
            validate_credentials

            if [[ "$DEPLOY_MODE" != "single" ]]; then
                deploy_multi_account
            else
                discover_aws_resources

                if prompt_confirm "Would you like to perform a dry-run first?" "Y"; then
                    DRY_RUN=true
                    perform_dry_run
                    DRY_RUN=false
                fi

                case "$DEPLOYMENT_TYPE" in
                    *"ECS"*)
                        if [[ -z "$task_def_file" ]]; then
                            task_def_file=$(prompt_input "Enter path to ECS task definition JSON file" "TASK_DEF_FILE")
                        fi

                        local cluster_name="" service_name=""
                        if prompt_confirm "Do you want to update an ECS service after registration?" "N"; then
                            cluster_name=$(prompt_input "Enter ECS cluster name" "ECS_CLUSTER")
                            service_name=$(prompt_input "Enter ECS service name" "ECS_SERVICE")
                        fi

                        deploy_ecs_fargate "$task_def_file" "${cluster_name:-}" "${service_name:-}"
                        ;;
                esac

                case "$DEPLOYMENT_TYPE" in
                    *"EKS"*) deploy_eks ;;
                esac

                run_tests || true
                generate_summary
            fi
            ;;

        deploy-org)
            init_state
            check_prerequisites || exit 1

            if $INTERACTIVE; then
                collect_configuration
            else
                [[ -z "${FALCON_CLIENT_ID:-}" ]] && die "FALCON_CLIENT_ID is required"
                [[ -z "${FALCON_CLIENT_SECRET:-}" ]] && die "FALCON_CLIENT_SECRET is required"
                [[ -z "${FALCON_CID:-}" ]] && die "FALCON_CID is required"
                FALCON_CLOUD="${FALCON_CLOUD:-us-1}"
                AWS_REGION="${AWS_REGION:-us-east-1}"
                DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-ECS Fargate (Container Sensor - Sidecar)}"
                ECR_REPO_NAME="${ECR_REPO_NAME:-falcon-sensor/falcon-container}"
                SENSOR_PLATFORM="${SENSOR_PLATFORM:-x86_64}"
                if [[ "$DEPLOY_MODE" == "single" ]]; then
                    DEPLOY_MODE="org"
                fi
            fi

            validate_credentials
            deploy_multi_account
            ;;
        
        deploy-ecs)
            [[ -z "$task_def_file" ]] && die "Usage: $SCRIPT_NAME deploy-ecs <task-definition-file>"
            init_state
            check_prerequisites || exit 1
            
            if $INTERACTIVE; then
                collect_configuration
            else
                [[ -z "${FALCON_CLIENT_ID:-}" ]] && die "FALCON_CLIENT_ID is required"
                [[ -z "${FALCON_CLIENT_SECRET:-}" ]] && die "FALCON_CLIENT_SECRET is required"
                [[ -z "${FALCON_CID:-}" ]] && die "FALCON_CID is required"
                DEPLOYMENT_TYPE="ECS Fargate (Container Sensor - Sidecar)"
                FALCON_CLOUD="${FALCON_CLOUD:-us-1}"
                AWS_REGION="${AWS_REGION:-us-east-1}"
                ECR_REPO_NAME="${ECR_REPO_NAME:-falcon-sensor/falcon-container}"
            fi
            
            validate_credentials
            
            if $DRY_RUN; then perform_dry_run; fi
            
            deploy_ecs_fargate "$task_def_file" "${ECS_CLUSTER:-}" "${ECS_SERVICE:-}"
            run_tests || true
            generate_summary
            ;;
        
        deploy-eks)
            init_state
            check_prerequisites || exit 1
            
            if $INTERACTIVE; then
                collect_configuration
            else
                [[ -z "${FALCON_CLIENT_ID:-}" ]] && die "FALCON_CLIENT_ID is required"
                [[ -z "${FALCON_CLIENT_SECRET:-}" ]] && die "FALCON_CLIENT_SECRET is required"
                [[ -z "${FALCON_CID:-}" ]] && die "FALCON_CID is required"
                DEPLOYMENT_TYPE="EKS (Node Sensor - DaemonSet via Helm)"
                FALCON_CLOUD="${FALCON_CLOUD:-us-1}"
                AWS_REGION="${AWS_REGION:-us-east-1}"
                HELM_NAMESPACE="${HELM_NAMESPACE:-falcon-system}"
                HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-falcon-sensor}"
                ECR_REPO_NAME="${ECR_REPO_NAME:-falcon-sensor/falcon-node-sensor}"
            fi
            
            validate_credentials
            
            if $DRY_RUN; then perform_dry_run; fi
            
            deploy_eks
            run_tests || true
            generate_summary
            ;;
        
        status) show_status ;;
        
        rollback)
            print_header "Manual Rollback"
            
            if [[ ! -f "$STATE_FILE" ]]; then
                die "No deployment state found"
            fi
            
            while IFS= read -r action; do
                [[ -n "$action" ]] && ROLLBACK_ACTIONS+=("$action")
            done < <(jq -r '.rollback_actions[]?.command // empty' "$STATE_FILE")
            
            if [[ ${#ROLLBACK_ACTIONS[@]} -eq 0 ]]; then
                print_info "No rollback actions found"
                exit 0
            fi
            
            echo "The following rollback actions will be performed:"
            for action in "${ROLLBACK_ACTIONS[@]}"; do
                echo "  - $action"
            done
            echo ""
            
            if prompt_confirm "Proceed with rollback?"; then
                perform_rollback
            fi
            ;;
        
        cleanup)
            print_header "Cleanup"
            
            if prompt_confirm "This will remove all Falcon sensor deployments. Continue?" "N"; then
                if command -v helm &> /dev/null && command -v kubectl &> /dev/null; then
                    local namespace="${HELM_NAMESPACE:-falcon-system}"
                    local release="${HELM_RELEASE_NAME:-falcon-sensor}"
                    
                    if helm status "$release" -n "$namespace" &> /dev/null; then
                        print_info "Uninstalling Helm release: $release"
                        helm uninstall "$release" -n "$namespace" || true
                    fi
                    
                    if kubectl get namespace "$namespace" &> /dev/null; then
                        print_info "Deleting namespace: $namespace"
                        kubectl delete namespace "$namespace" || true
                    fi
                fi
                
                if [[ -f "$STATE_FILE" ]]; then
                    rm -f "$STATE_FILE"
                    print_success "State file removed"
                fi
                
                print_success "Cleanup completed"
            fi
            ;;
        
        test)
            init_state
            if $INTERACTIVE; then collect_configuration; fi
            run_tests
            ;;
        
        help) show_help ;;
        
        *) print_error "Unknown command: $command"; show_help; exit 1 ;;
    esac
}

main "$@"
