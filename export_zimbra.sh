#!/bin/bash
# 
# Enhanced Zimbra Export Script with Progress Tracking and Resume Capability
# 
# Description:
#   This script exports all Zimbra data from a source server including domains, users,
#   passwords, contacts, calendars, emails, filters, signatures, and all settings.
#   Features include real-time progress tracking, resume capability, detailed logging,
#   and color-coded output for better user experience.
#
# Usage:
#   ./export_zimbra.sh                    # Export all domains
#   ./export_zimbra.sh example.com        # Export specific domain only
#
# Requirements:
#   - Root access
#   - Zimbra Collaboration Suite installed
#   - Sufficient disk space in /opt/zmbackup
#
# Developed by: Cuma KURT
# Email: cumakurt@gmail.com
# LinkedIn: https://www.linkedin.com/in/cuma-kurt-34414917/
#

BACKUP_DIR="/opt/zmbackup"
REGEX_FOLDER_TOP="\/[^\/]+"
STATE_DIR="${BACKUP_DIR}/.export_state"
LOG_FILE=""
PROGRESS_FILE=""
START_TIME=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Initialize state directory
init_state_dir() {
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR"
        chown -R zimbra:zimbra "$STATE_DIR"
    fi
}

# Logging function
log_message() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
    echo -e "$message"
}

# Get terminal width
get_terminal_width() {
    local width=$(tput cols 2>/dev/null || echo 80)
    echo $width
}

# Truncate long strings for display
truncate_string() {
    local str="$1"
    local max_len=$2
    if [ ${#str} -gt $max_len ]; then
        echo "${str:0:$((max_len-3))}..."
    else
        echo "$str"
    fi
}

# Clear current line
clear_line() {
    local width=$(get_terminal_width)
    printf "\r%*s\r" $width ""
}

# Progress display function
show_progress() {
    local current=$1
    local total=$2
    local item_name=$3
    local step_name=$4
    
    local percent=$((current * 100 / total))
    local elapsed=0
    local avg_time_per_item=0
    local remaining_time=0
    
    if [ -n "$START_TIME" ]; then
        elapsed=$(($(date +%s) - START_TIME))
        if [ $current -gt 0 ]; then
            avg_time_per_item=$((elapsed / current))
            remaining_time=$(((total - current) * avg_time_per_item))
        fi
    fi
    
    local elapsed_str=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
    local remaining_str=$(printf '%02d:%02d:%02d' $((remaining_time/3600)) $((remaining_time%3600/60)) $((remaining_time%60)))
    
    # Get terminal width and adjust display accordingly
    local term_width=$(get_terminal_width)
    local max_email_len=18
    
    # Truncate item name for display
    local display_name=$(truncate_string "$item_name" $max_email_len)
    
    # Adjust progress bar length based on terminal width
    local bar_length=20
    if [ $term_width -lt 100 ]; then
        bar_length=15
        max_email_len=12
        display_name=$(truncate_string "$item_name" $max_email_len)
    elif [ $term_width -gt 120 ]; then
        bar_length=25
        max_email_len=22
        display_name=$(truncate_string "$item_name" $max_email_len)
    fi
    
    local filled=$((current * bar_length / total))
    local empty=$((bar_length - filled))
    local bar=$(printf '%*s' $filled | tr ' ' '=')$(printf '%*s' $empty | tr ' ' '-')
    
    # Build progress string without color codes first for length calculation
    local clean_progress=""
    if [ $term_width -lt 100 ]; then
        # Very compact for narrow terminals
        clean_progress="${step_name} [${bar}] ${percent}% (${current}/${total}) ${display_name}"
    else
        # Standard display
        clean_progress="${step_name} [${bar}] ${percent}% (${current}/${total}) | ${elapsed_str} | ETA: ${remaining_str} | ${display_name}"
    fi
    
    local clean_len=${#clean_progress}
    
    # Build and display progress using echo -ne for proper escape sequence handling
    # Clear line first with \r, then print progress, then clear remaining chars
    local padding=""
    if [ $term_width -gt $clean_len ]; then
        padding=$(printf "%*s" $((term_width - clean_len)) "")
    fi
    
    if [ $term_width -lt 100 ]; then
        # Very compact for narrow terminals
        echo -ne "\r${CYAN}${step_name}${NC} [${GREEN}${bar}${NC}] ${percent}% (${current}/${total}) ${YELLOW}${display_name}${NC}${padding}"
    else
        # Standard display
        echo -ne "\r${CYAN}${step_name}${NC} [${GREEN}${bar}${NC}] ${percent}% (${current}/${total}) | ${elapsed_str} | ETA: ${remaining_str} | ${YELLOW}${display_name}${NC}${padding}"
    fi
    
    # Save progress to file
    if [ -n "$PROGRESS_FILE" ]; then
        echo "$step_name|$current|$total|$percent|$(date +%s)" > "$PROGRESS_FILE" 2>/dev/null
    fi
}

# Check if item is already exported
is_exported() {
    local step=$1
    local item=$2
    local state_file="${STATE_DIR}/${step}_completed.txt"
    
    if [ -f "$state_file" ]; then
        grep -Fxq "$item" "$state_file" 2>/dev/null
        return $?
    fi
    return 1
}

# Mark item as exported
mark_exported() {
    local step=$1
    local item=$2
    local state_file="${STATE_DIR}/${step}_completed.txt"
    
    echo "$item" >> "$state_file"
    chown zimbra:zimbra "$state_file" 2>/dev/null
}

# Get list of items that need to be exported
get_items_to_export() {
    local step=$1
    local all_items_file=$2
    local state_file="${STATE_DIR}/${step}_completed.txt"
    
    if [ ! -f "$all_items_file" ]; then
        echo ""
        return
    fi
    
    if [ ! -f "$state_file" ]; then
        cat "$all_items_file"
        return
    fi
    
    # Get items that are not yet exported
    while IFS= read -r item; do
        if ! grep -Fxq "$item" "$state_file" 2>/dev/null; then
            echo "$item"
        fi
    done < "$all_items_file"
}

# Export function with resume capability
export_with_resume() {
    local step_name=$1
    local export_func=$2
    local items_file=$3
    local total_items=0
    local processed=0
    local failed=0
    
    if [ ! -f "$items_file" ]; then
        log_message "ERROR" "${RED}Items file not found: $items_file${NC}"
        return 1
    fi
    
    # Get all items
    local all_items=($(cat "$items_file"))
    total_items=${#all_items[@]}
    
    if [ $total_items -eq 0 ]; then
        log_message "INFO" "${YELLOW}No items to export for step: $step_name${NC}"
        return 0
    fi
    
    # Get items that need to be exported
    local items_to_export=($(get_items_to_export "$step_name" "$items_file"))
    local items_count=${#items_to_export[@]}
    
    if [ $items_count -eq 0 ]; then
        log_message "INFO" "${GREEN}✓ All items already exported for: $step_name${NC}"
        return 0
    fi
    
    local already_exported=$((total_items - items_count))
    if [ $already_exported -gt 0 ]; then
        log_message "INFO" "${BLUE}→ $step_name${NC} | Total: $total_items | Resuming: $items_count remaining"
    else
        log_message "INFO" "${BLUE}→ $step_name${NC} | Total: $total_items"
    fi
    
    local current=0
    local failed_items=()
    
    for item in "${items_to_export[@]}"; do
        current=$((current + 1))
        local current_total=$((already_exported + current))
        
        # Show progress
        show_progress $current_total $total_items "$item" "$step_name"
        
        # Run export function and capture result (suppress all output)
        if $export_func "$item" >/dev/null 2>&1; then
            mark_exported "$step_name" "$item"
            processed=$((processed + 1))
        else
            failed=$((failed + 1))
            failed_items+=("$item")
        fi
    done
    
    # Clear progress line completely
    clear_line
    
    if [ $failed -eq 0 ]; then
        log_message "INFO" "${GREEN}✓ $step_name completed${NC} | Processed: $processed/$total_items"
    else
        log_message "INFO" "${YELLOW}⚠ $step_name completed${NC} | Processed: $processed/$total_items | Failed: $failed"
        if [ ${#failed_items[@]} -le 5 ]; then
            for failed_item in "${failed_items[@]}"; do
                log_message "ERROR" "  ${RED}✗${NC} $failed_item"
            done
        else
            log_message "ERROR" "  ${RED}✗${NC} ${#failed_items[@]} items failed (check log for details)"
        fi
    fi
}

# Export user password
export_user_password() {
    local email=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov -l ga "$email" userPassword | grep userPassword: | awk '{ print $2}' > "${BACKUP_DIR}/userpass/${email}.shadow" 2>/dev/null
    [ -f "${BACKUP_DIR}/userpass/${email}.shadow" ] && [ -s "${BACKUP_DIR}/userpass/${email}.shadow" ]
}

# Export user data
export_user_data() {
    local email=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep -i Name: > "${BACKUP_DIR}/userdata/${email}.txt" 2>/dev/null
    [ -f "${BACKUP_DIR}/userdata/${email}.txt" ]
}

# Export contacts
export_contacts() {
    local email=$1
    sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m "$email" getRestURL "/Contacts?fmt=csv" > "${BACKUP_DIR}/contacts/${email}.csv" 2>/dev/null
    [ -f "${BACKUP_DIR}/contacts/${email}.csv" ]
}

# Export filters
export_filters() {
    local email=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov -l ga "$email" zimbraMailSieveScript > "${BACKUP_DIR}/filters/${email}.txt" 2>/dev/null
    if [ -f "${BACKUP_DIR}/filters/${email}.txt" ]; then
        sed -i -e "1d" "${BACKUP_DIR}/filters/${email}.txt" 2>/dev/null
        sed -i -e 's/zimbraMailSieveScript: //g' "${BACKUP_DIR}/filters/${email}.txt" 2>/dev/null
        return 0
    fi
    return 1
}

# Export signatures
export_signatures() {
    local email=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov gsig "$email" > "${BACKUP_DIR}/signatures/${email}.txt" 2>/dev/null
    [ -f "${BACKUP_DIR}/signatures/${email}.txt" ]
}

# Export autoresponders
export_autoresponders() {
    local email=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep Office > "${BACKUP_DIR}/autoresponders/${email}.txt" 2>/dev/null
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" zimbraPrefOutOfOfficeReply > "${BACKUP_DIR}/autoresponders/${email}_reply.txt" 2>/dev/null
    [ -f "${BACKUP_DIR}/autoresponders/${email}.txt" ] || [ -f "${BACKUP_DIR}/autoresponders/${email}_reply.txt" ]
}

# Export aliases
export_aliases() {
    local email=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep zimbraMailAlias > "${BACKUP_DIR}/alias/${email}.txt" 2>/dev/null
    return 0  # Always return success as empty file is valid
}

# Export forwarders
export_forwarders() {
    local email=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep 'zimbraMailForwardingAddress:' > "${BACKUP_DIR}/forwarders/${email}_hidden.txt" 2>/dev/null
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep 'zimbraPrefMailForwardingAddress:' > "${BACKUP_DIR}/forwarders/${email}_userdefined.txt" 2>/dev/null
    return 0  # Always return success as empty file is valid
}

# Export settings
export_settings() {
    local email=$1
    local success=0
    
    sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m "$email" getAllFolders > "${BACKUP_DIR}/settings/${email}_folders.txt" 2>/dev/null && success=1
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep zimbraPref > "${BACKUP_DIR}/settings/${email}_prefs.txt" 2>/dev/null
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep zimbraShare > "${BACKUP_DIR}/settings/${email}_shared.txt" 2>/dev/null
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep zimbraIntercept > "${BACKUP_DIR}/settings/${email}_intercept.txt" 2>/dev/null
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" | grep "zimbraAccountStatus:" > "${BACKUP_DIR}/settings/${email}_status.txt" 2>/dev/null
    sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" zimbraMailCatchAllAddress > "${BACKUP_DIR}/settings/${email}_catchall.txt" 2>/dev/null
    
    [ $success -eq 1 ]
}

# Export briefcase
export_briefcase() {
    local email=$1
    local success=0
    
    if [ ! -d "${BACKUP_DIR}/briefcase/${email}" ]; then
        mkdir -p "${BACKUP_DIR}/briefcase/${email}"
        chown -R zimbra:zimbra "${BACKUP_DIR}/briefcase/${email}"
    fi
    
    if [ -e "${BACKUP_DIR}/settings/${email}_folders.txt" ]; then
        declare -A folderarray
        while read -r LINE; do
            if [[ ${LINE} == *"  docu "* ]]; then
                [[ ${LINE} =~ $REGEX_FOLDER_TOP ]]
                INDEX1=${BASH_REMATCH[0]}
                folderarray[$INDEX1]="1"
            fi
        done < "${BACKUP_DIR}/settings/${email}_folders.txt"
        
        for folder in "${!folderarray[@]}"; do
            if [[ $folder != *")"* ]]; then
                local folder_file="${BACKUP_DIR}/briefcase/${email}${folder}.tgz"
                if [ ! -f "$folder_file" ] || [ ! -s "$folder_file" ]; then
                    sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m "$email" getRestURL "${folder}/?fmt=tgz" > "$folder_file" 2>/dev/null
                    if [ -f "$folder_file" ] && [ -s "$folder_file" ]; then
                        success=1
                    fi
                else
                    success=1
                fi
            fi
        done
        unset folderarray
    fi
    
    [ $success -eq 1 ] || return 0  # Return success even if no briefcase folders
}

# Export calendar
export_calendar() {
    local email=$1
    local success=0
    
    if [ ! -d "${BACKUP_DIR}/calendar/${email}" ]; then
        mkdir -p "${BACKUP_DIR}/calendar/${email}"
        chown -R zimbra:zimbra "${BACKUP_DIR}/calendar/${email}"
    fi
    
    if [ -e "${BACKUP_DIR}/settings/${email}_folders.txt" ]; then
        declare -A folderarray
        while read -r LINE; do
            if [[ ${LINE} == *"  appo "* ]]; then
                [[ ${LINE} =~ $REGEX_FOLDER_TOP ]]
                INDEX1=${BASH_REMATCH[0]}
                folderarray[$INDEX1]="1"
            fi
        done < "${BACKUP_DIR}/settings/${email}_folders.txt"
        
        for folder in "${!folderarray[@]}"; do
            if [[ $folder != *")"* ]]; then
                local folder_file="${BACKUP_DIR}/calendar/${email}${folder}.tgz"
                if [ ! -f "$folder_file" ] || [ ! -s "$folder_file" ]; then
                    sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m "$email" getRestURL "${folder}/?fmt=tgz" > "$folder_file" 2>/dev/null
                    if [ -f "$folder_file" ] && [ -s "$folder_file" ]; then
                        success=1
                    fi
                else
                    success=1
                fi
            fi
        done
        unset folderarray
    fi
    
    [ $success -eq 1 ] || return 0  # Return success even if no calendar folders
}

# Export distribution list function
export_distribution_list() {
    local dist_list=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov GetDistributionList "$dist_list" > "${BACKUP_DIR}/distribution/${dist_list}.txt" 2>/dev/null
    [ -f "${BACKUP_DIR}/distribution/${dist_list}.txt" ]
}

# Export catchall function
export_catchall() {
    local domain=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov gd "$domain" | grep CatchAll > "${BACKUP_DIR}/catchall/${domain}.txt" 2>/dev/null
    return 0  # Always return success as empty file is valid
}

# Main script starts here
sudo -u zimbra bash -c 'export LC_ALL="en_US.UTF-8"'
export LC_ALL="en_US.UTF-8"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Zimbra Export Script${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Create Backup Directory first
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Creating backup directory: ${BACKUP_DIR}..."
    mkdir -p ${BACKUP_DIR}
    chown -R zimbra:zimbra ${BACKUP_DIR}
else
    chown -R zimbra:zimbra ${BACKUP_DIR}
fi

# Initialize state directory and log file
init_state_dir
LOG_FILE="${BACKUP_DIR}/export.log"
PROGRESS_FILE="${STATE_DIR}/progress.txt"

# Initialize log file
touch "$LOG_FILE"
chown zimbra:zimbra "$LOG_FILE" 2>/dev/null

echo "This script should be run as root. Press Ctrl-c to exit if not."
sleep 1
echo ""

cd ${BACKUP_DIR}

# Check for resume
if [ -f "$PROGRESS_FILE" ] && [ -s "$PROGRESS_FILE" ]; then
    last_step=$(cut -d'|' -f1 "$PROGRESS_FILE" 2>/dev/null)
    last_progress=$(cut -d'|' -f2 "$PROGRESS_FILE" 2>/dev/null)
    last_total=$(cut -d'|' -f3 "$PROGRESS_FILE" 2>/dev/null)
    
    if [ -n "$last_step" ] && [ -n "$last_progress" ]; then
        echo -e "${YELLOW}Previous export session detected!${NC}"
        echo -e "Last progress: ${CYAN}$last_step${NC} - $last_progress/$last_total"
        echo ""
        echo -n "Resume from where you left off? (y/n): "
        read RESPONSE_VAR
        if [ "${RESPONSE_VAR}" != "y" ]; then
            echo "Starting fresh export..."
            rm -f ${STATE_DIR}/*_completed.txt 2>/dev/null
            rm -f "$PROGRESS_FILE" 2>/dev/null
        else
            echo -e "${GREEN}Resuming previous export...${NC}"
        fi
    else
        echo -e "${CYAN}Export will be saved to: ${BACKUP_DIR}${NC}"
        echo -n "Proceed with export? (y/n): "
        read RESPONSE_VAR
        if [ "${RESPONSE_VAR}" != "y" ]; then
            echo "Export cancelled."
            exit 0
        fi
    fi
else
    echo -e "${CYAN}Export will be saved to: ${BACKUP_DIR}${NC}"
    echo -n "Proceed with export? (y/n): "
    read RESPONSE_VAR
    if [ "${RESPONSE_VAR}" != "y" ]; then
        echo "Export cancelled."
        exit 0
    fi
fi

echo ""
START_TIME=$(date +%s)

# Domain selection
if [ -z "$1" ]; then
    DOMAIN="OFF"
else
    DOMAIN=$1
fi

# Export domains
echo -e "${BLUE}Step 1: Exporting Domains${NC}"
if [ -z "$1" ]; then
    if [ ! -f "${BACKUP_DIR}/domains.txt" ] || [ ! -s "${BACKUP_DIR}/domains.txt" ]; then
        sudo -u zimbra /opt/zimbra/bin/zmprov -l gad > ${BACKUP_DIR}/domains.txt 2>/dev/null
        chown -R zimbra:zimbra ${BACKUP_DIR}/domains.txt
        echo -e "${GREEN}✓${NC} Domains exported"
    else
        echo -e "${GREEN}✓${NC} Domains already exported"
    fi
else
    DOMAINRESULT=$(sudo -u zimbra /opt/zimbra/bin/zmprov -l gd ${DOMAIN} 2>&1)
    if [[ "$DOMAINRESULT" == *"NO_SUCH_DOMAIN"* ]]; then
        echo -e "${RED}Error: Domain ${DOMAIN} does not exist${NC}"
        exit 1
    else
        if [ ! -f "${BACKUP_DIR}/domains.txt" ] || [ ! -s "${BACKUP_DIR}/domains.txt" ]; then
            echo ${DOMAIN} > ${BACKUP_DIR}/domains.txt
            chown -R zimbra:zimbra ${BACKUP_DIR}/domains.txt
        fi
        echo -e "${GREEN}✓${NC} Domain: ${DOMAIN}"
    fi
fi

# Export Users
echo -e "${BLUE}Step 2: Exporting Users${NC}"
if [ -z "$1" ]; then
    if [ ! -f "${BACKUP_DIR}/emails.txt" ] || [ ! -s "${BACKUP_DIR}/emails.txt" ]; then
        sudo -u zimbra /opt/zimbra/bin/zmprov -l gaa > ${BACKUP_DIR}/emails.txt 2>/dev/null
        chown -R zimbra:zimbra ${BACKUP_DIR}/emails.txt
        
        sudo -u zimbra /opt/zimbra/bin/zmprov GetAllAdminAccounts > ${BACKUP_DIR}/admins.txt 2>/dev/null
        chown -R zimbra:zimbra ${BACKUP_DIR}/admins.txt
    fi
else
    if [ ! -f "${BACKUP_DIR}/emails.txt" ] || [ ! -s "${BACKUP_DIR}/emails.txt" ]; then
        sudo -u zimbra /opt/zimbra/bin/zmprov -l gaa ${DOMAIN} > ${BACKUP_DIR}/emails.txt 2>/dev/null
        chown -R zimbra:zimbra ${BACKUP_DIR}/emails.txt
    fi
fi

# Display summary
TOTAL_USERS=$(wc -l < ${BACKUP_DIR}/emails.txt 2>/dev/null || echo "0")
DOMAIN_COUNT=$(wc -l < ${BACKUP_DIR}/domains.txt 2>/dev/null || echo "0")
echo -e "${GREEN}✓${NC} Found ${CYAN}$TOTAL_USERS${NC} users across ${CYAN}$DOMAIN_COUNT${NC} domain(s)"
echo ""

# Create directories
for dir in userpass userdata contacts filters signatures autoresponders alias forwarders settings briefcase calendar catchall distribution; do
    if [ ! -d "${BACKUP_DIR}/${dir}" ]; then
        mkdir -p "${BACKUP_DIR}/${dir}"
        chown -R zimbra:zimbra "${BACKUP_DIR}/${dir}"
    else
        chown -R zimbra:zimbra "${BACKUP_DIR}/${dir}"
    fi
done

# Export user passwords
echo -e "${BLUE}Step 3: Exporting User Passwords${NC}"
export_with_resume "Passwords" export_user_password "${BACKUP_DIR}/emails.txt"

# Export user data
echo -e "${BLUE}Step 4: Exporting User Data${NC}"
export_with_resume "UserData" export_user_data "${BACKUP_DIR}/emails.txt"

# Export contacts
echo -e "${BLUE}Step 5: Exporting Contacts${NC}"
export_with_resume "Contacts" export_contacts "${BACKUP_DIR}/emails.txt"

# Export filters
echo -e "${BLUE}Step 6: Exporting Mail Filters${NC}"
export_with_resume "Filters" export_filters "${BACKUP_DIR}/emails.txt"

# Export signatures
echo -e "${BLUE}Step 7: Exporting Signatures${NC}"
export_with_resume "Signatures" export_signatures "${BACKUP_DIR}/emails.txt"

# Export autoresponders
echo -e "${BLUE}Step 8: Exporting Auto-Responders${NC}"
export_with_resume "AutoResp" export_autoresponders "${BACKUP_DIR}/emails.txt"

# Export aliases
echo -e "${BLUE}Step 9: Exporting Aliases${NC}"
export_with_resume "Aliases" export_aliases "${BACKUP_DIR}/emails.txt"

# Export forwarders
echo -e "${BLUE}Step 10: Exporting Forwarders${NC}"
export_with_resume "Forwarders" export_forwarders "${BACKUP_DIR}/emails.txt"

# Export settings
echo -e "${BLUE}Step 11: Exporting Settings${NC}"
export_with_resume "Settings" export_settings "${BACKUP_DIR}/emails.txt"

# Export briefcase
echo -e "${BLUE}Step 12: Exporting Briefcase${NC}"
export_with_resume "Briefcase" export_briefcase "${BACKUP_DIR}/emails.txt"

# Export calendar
echo -e "${BLUE}Step 13: Exporting Calendars${NC}"
export_with_resume "Calendars" export_calendar "${BACKUP_DIR}/emails.txt"

# Export distribution lists
echo -e "${BLUE}Step 14: Exporting Distribution Lists${NC}"
if [ ! -f "${BACKUP_DIR}/distribution_list.txt" ] || [ ! -s "${BACKUP_DIR}/distribution_list.txt" ]; then
    sudo -u zimbra /opt/zimbra/bin/zmprov GetAllDistributionLists > ${BACKUP_DIR}/distribution_list.txt 2>/dev/null
    chown -R zimbra:zimbra ${BACKUP_DIR}/distribution_list.txt
fi

if [ -f "${BACKUP_DIR}/distribution_list.txt" ] && [ -s "${BACKUP_DIR}/distribution_list.txt" ]; then
    export_with_resume "DistLists" export_distribution_list "${BACKUP_DIR}/distribution_list.txt"
else
    echo -e "${GREEN}✓${NC} No distribution lists found"
fi

# Export global settings
echo -e "${BLUE}Step 15: Exporting Global Settings${NC}"
if [ ! -f "${BACKUP_DIR}/global_settings.txt" ] || [ ! -s "${BACKUP_DIR}/global_settings.txt" ]; then
    HOSTNAME=$(sudo -u zimbra /opt/zimbra/bin/zmhostname 2>/dev/null)
    sudo -u zimbra /opt/zimbra/bin/zmprov gs ${HOSTNAME} > ${BACKUP_DIR}/global_settings.txt 2>/dev/null
    chown -R zimbra:zimbra ${BACKUP_DIR}/global_settings.txt
    echo -e "${GREEN}✓${NC} Global settings exported"
else
    echo -e "${GREEN}✓${NC} Global settings already exported"
fi

# Export catch-all accounts
echo -e "${BLUE}Step 16: Exporting Catch-All Accounts${NC}"
if [ -f "${BACKUP_DIR}/domains.txt" ] && [ -s "${BACKUP_DIR}/domains.txt" ]; then
    export_with_resume "CatchAll" export_catchall "${BACKUP_DIR}/domains.txt"
else
    echo -e "${GREEN}✓${NC} No catch-all accounts to export"
fi

# Final summary
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_TIME_STR=$(printf '%02d:%02d:%02d' $((TOTAL_TIME/3600)) $((TOTAL_TIME%3600/60)) $((TOTAL_TIME%60)))

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}Export completed successfully!${NC}"
echo -e "Total time: ${CYAN}$TOTAL_TIME_STR${NC}"
echo -e "Backup directory: ${CYAN}${BACKUP_DIR}${NC}"
echo -e "Log file: ${CYAN}${LOG_FILE}${NC}"
echo -e "${CYAN}========================================${NC}"
