#!/bin/bash
# 
# Enhanced Zimbra Import Script with Progress Tracking and Resume Capability
#
# Description:
#   This script imports Zimbra data to a destination server including domains, users,
#   passwords, contacts, calendars, emails (via imapsync), filters, signatures, and all settings.
#   Features include real-time progress tracking, resume capability, detailed logging,
#   email-only mode for re-syncing, and enhanced imapsync integration with individual log files.
#
# Usage:
#   ./import_zimbra.sh <source_server_ip>                    # Full import
#   ./import_zimbra.sh <source_server_ip> /opt/zmbackup      # Custom backup directory
#   ./import_zimbra.sh <source_server_ip> /opt/zmbackup --email-only  # Email-only mode
#
# Requirements:
#   - Root access
#   - Zimbra Collaboration Suite installed on destination server
#   - imapsync installed (for email migration)
#   - SSH access to source server (for rsync)
#   - Network connectivity between source and destination servers
#
# Developed by: Cuma KURT
# Email: cumakurt@gmail.com
# LinkedIn: https://www.linkedin.com/in/cuma-kurt-34414917/
#

BACKUP_DIR="/opt/zmbackup"
STATE_DIR="${BACKUP_DIR}/.import_state"
LOG_FILE=""
PROGRESS_FILE=""
START_TIME=""

# Preferences that will be imported
IMPORT_PREF=("zimbraPrefLocale" "zimbraPrefConversationOrder" "zimbraPrefDefaultPrintFontSize" "zimbraPrefDisplayExternalImages" "zimbraPrefFolderTreeOpen" "zimbraPrefHtmlEditorDefaultFontColor" "zimbraPrefHtmlEditorDefaultFontFamily" "zimbraPrefHtmlEditorDefaultFontSize" "zimbraPrefComposeInNewWindow" "zimbraPrefGroupMailBy" "zimbraPrefHtmlEditorDefaultFontColor" "zimbraPrefHtmlEditorDefaultFontSize" "zimbraPrefFromAddress" "zimbraPrefFromDisplay" "zimbraPrefGalAutoCompleteEnabled" "zimbraPrefComposeFormat" "zimbraPrefCalendarViewTimeInterval" "zimbraPrefCalendarReminderDuration1" "zimbraPrefCalendarInitialView" "zimbraPrefFolderTreeOpen" "zimbraPrefMailTrustedSenderList" "zimbraPrefMandatorySpellCheckEnabled" "zimbraPrefOutOfOfficeReplyEnabled" "zimbraPrefTimeZoneId" "zimbraPrefSkin" "zimbraPrefFont" "zimbraPrefClientType" "zimbraPrefConvReadingPaneLocation")

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

# Check if item is already imported
is_imported() {
    local step=$1
    local item=$2
    local state_file="${STATE_DIR}/${step}_completed.txt"
    
    if [ -f "$state_file" ]; then
        grep -Fxq "$item" "$state_file" 2>/dev/null
        return $?
    fi
    return 1
}

# Mark item as imported
mark_imported() {
    local step=$1
    local item=$2
    local state_file="${STATE_DIR}/${step}_completed.txt"
    
    echo "$item" >> "$state_file"
    chown zimbra:zimbra "$state_file" 2>/dev/null
}

# Get list of items that need to be imported
get_items_to_import() {
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
    
    # Get items that are not yet imported
    while IFS= read -r item; do
        if ! grep -Fxq "$item" "$state_file" 2>/dev/null; then
            echo "$item"
        fi
    done < "$all_items_file"
}

# Import function with resume capability
import_with_resume() {
    local step_name=$1
    local import_func=$2
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
        log_message "INFO" "${YELLOW}No items to import for step: $step_name${NC}"
        return 0
    fi
    
    # Get items that need to be imported
    local items_to_import=($(get_items_to_import "$step_name" "$items_file"))
    local items_count=${#items_to_import[@]}
    
    if [ $items_count -eq 0 ]; then
        log_message "INFO" "${GREEN}✓ All items already imported for: $step_name${NC}"
        return 0
    fi
    
    local already_imported=$((total_items - items_count))
    if [ $already_imported -gt 0 ]; then
        log_message "INFO" "${BLUE}→ $step_name${NC} | Total: $total_items | Resuming: $items_count remaining"
    else
        log_message "INFO" "${BLUE}→ $step_name${NC} | Total: $total_items"
    fi
    
    local current=0
    local failed_items=()
    
    for item in "${items_to_import[@]}"; do
        current=$((current + 1))
        local current_total=$((already_imported + current))
        
        # Show progress
        show_progress $current_total $total_items "$item" "$step_name"
        
        # Run import function and capture result
        # For email imports, allow output to show errors (function handles its own output)
        if [ "$step_name" == "Emails" ]; then
            # Email import function handles its own output and logging
            if $import_func "$item"; then
                mark_imported "$step_name" "$item"
                processed=$((processed + 1))
            else
                failed=$((failed + 1))
                failed_items+=("$item")
            fi
        else
            # For other imports, suppress output as before
            if $import_func "$item" >/dev/null 2>&1; then
                mark_imported "$step_name" "$item"
                processed=$((processed + 1))
            else
                failed=$((failed + 1))
                failed_items+=("$item")
            fi
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

# Import function with resume capability and parallel processing (for emails)
import_with_resume_parallel() {
    local step_name=$1
    local import_func=$2
    local items_file=$3
    local max_parallel=${4:-10}  # Default to 10 parallel jobs
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
        log_message "INFO" "${YELLOW}No items to import for step: $step_name${NC}"
        return 0
    fi
    
    # Get items that need to be imported
    local items_to_import=($(get_items_to_import "$step_name" "$items_file"))
    local items_count=${#items_to_import[@]}
    
    if [ $items_count -eq 0 ]; then
        log_message "INFO" "${GREEN}✓ All items already imported for: $step_name${NC}"
        return 0
    fi
    
    local already_imported=$((total_items - items_count))
    if [ $already_imported -gt 0 ]; then
        log_message "INFO" "${BLUE}→ $step_name${NC} | Total: $total_items | Resuming: $items_count remaining | Parallel: $max_parallel"
    else
        log_message "INFO" "${BLUE}→ $step_name${NC} | Total: $total_items | Parallel: $max_parallel"
    fi
    
    local current=0
    local failed_items=()
    local running_jobs=()
    local interrupted=false
    
    # Create temporary directory for job tracking
    local job_dir=$(mktemp -d)
    
    # Signal handler for Ctrl+C (SIGINT) and SIGTERM
    cleanup_on_interrupt() {
        interrupted=true
        echo ""
        echo -e "${YELLOW}Interrupt signal received. Stopping all imapsync processes...${NC}"
        
        # Kill all running background jobs and their children
        for pid in "${running_jobs[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                # Kill the background job
                kill -TERM "$pid" 2>/dev/null
                # Kill all child processes (imapsync) of this job
                pkill -P "$pid" -TERM 2>/dev/null
            fi
        done
        
        # Wait a moment for graceful shutdown
        sleep 1
        
        # Force kill if still running
        for pid in "${running_jobs[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null
                pkill -P "$pid" -KILL 2>/dev/null
            fi
        done
        
        # Also kill any remaining imapsync processes (safety net)
        # This catches any imapsync processes that might have escaped
        pkill -TERM imapsync 2>/dev/null
        sleep 0.5
        pkill -KILL imapsync 2>/dev/null
        
        # Cleanup
        rm -rf "$job_dir" 2>/dev/null
        
        echo -e "${RED}All processes stopped.${NC}"
        echo ""
        exit 130
    }
    
    # Set up signal handlers
    trap cleanup_on_interrupt INT TERM
    trap "rm -rf $job_dir" EXIT
    
    # Function to check and process completed jobs
    check_completed_jobs() {
        local new_running_jobs=()
        for pid in "${running_jobs[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                # Job still running
                new_running_jobs+=("$pid")
            else
                # Job completed, wait for it and get result
                wait "$pid"
                local job_result=$?
                local job_email=$(cat "$job_dir/${pid}.email" 2>/dev/null 2>/dev/null || echo "")
                rm -f "$job_dir/${pid}.email" 2>/dev/null
                
                if [ -n "$job_email" ]; then
                    if [ $job_result -eq 0 ]; then
                        mark_imported "$step_name" "$job_email"
                        processed=$((processed + 1))
                    else
                        failed=$((failed + 1))
                        failed_items+=("$job_email")
                    fi
                    
                    current=$((current + 1))
                    local current_total=$((already_imported + current))
                    show_progress $current_total $total_items "$job_email" "$step_name"
                fi
            fi
        done
        running_jobs=("${new_running_jobs[@]}")
    }
    
    for item in "${items_to_import[@]}"; do
        # Check if interrupted
        if [ "$interrupted" = true ]; then
            break
        fi
        
        # Wait if we have reached max parallel jobs
        while [ ${#running_jobs[@]} -ge $max_parallel ] && [ "$interrupted" = false ]; do
            check_completed_jobs
            # Small sleep to avoid busy waiting
            if [ ${#running_jobs[@]} -ge $max_parallel ]; then
                sleep 0.3
            fi
        done
        
        # Check if interrupted before starting new job
        if [ "$interrupted" = true ]; then
            break
        fi
        
        # Start new job in background
        (
            # Set up signal handler in child process to propagate to imapsync
            trap 'exit 130' INT TERM
            $import_func "$item"
        ) &
        local pid=$!
        running_jobs+=("$pid")
        echo "$item" > "$job_dir/${pid}.email"
    done
    
    # Wait for all remaining jobs to complete (unless interrupted)
    while [ ${#running_jobs[@]} -gt 0 ] && [ "$interrupted" = false ]; do
        check_completed_jobs
        if [ ${#running_jobs[@]} -gt 0 ]; then
            sleep 0.3
        fi
    done
    
    # If interrupted, cleanup remaining jobs
    if [ "$interrupted" = true ]; then
        cleanup_on_interrupt
        return 130
    fi
    
    # Cleanup
    rm -rf "$job_dir"
    
    # Clear progress line completely
    clear_line
    
    # Report results
    if [ $failed -eq 0 ]; then
        log_message "INFO" "${GREEN}✓ $step_name completed${NC} | Processed: $processed/$total_items"
    else
        log_message "INFO" "${YELLOW}⚠ $step_name completed${NC} | Processed: $processed/$total_items | Failed: $failed"
        
        # Detailed failure report for emails
        if [ "$step_name" == "Emails" ] && [ ${#failed_items[@]} -gt 0 ]; then
            echo ""
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo -e "${RED}Failed Email Import Report${NC}"
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo ""
            
            local imapsync_log_dir="${BACKUP_DIR}/imapsync_logs"
            for failed_email in "${failed_items[@]}"; do
                local log_file="${imapsync_log_dir}/${failed_email}.log"
                echo -e "${RED}✗${NC} ${failed_email}"
                
                # Try to extract error details from log file
                if [ -f "$log_file" ] && [ -s "$log_file" ]; then
                    local error_msg=$(grep -iE "ERROR|FATAL|Failed|Authentication|Login" "$log_file" 2>/dev/null | head -3 | sed 's/^/    /')
                    if [ -n "$error_msg" ]; then
                        echo "$error_msg"
                    else
                        echo "    Check log file: $log_file"
                    fi
                else
                    echo "    No log file found"
                fi
                echo ""
            done
            
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo ""
            
            # Also log to file
            {
                echo "════════════════════════════════════════════════════════════"
                echo "Failed Email Import Report"
                echo "════════════════════════════════════════════════════════════"
                echo ""
                for failed_email in "${failed_items[@]}"; do
                    local log_file="${imapsync_log_dir}/${failed_email}.log"
                    echo "✗ ${failed_email}"
                    
                    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
                        local error_msg=$(grep -iE "ERROR|FATAL|Failed|Authentication|Login" "$log_file" 2>/dev/null | head -5)
                        if [ -n "$error_msg" ]; then
                            echo "$error_msg" | sed 's/^/    /'
                        else
                            echo "    Check log file: $log_file"
                        fi
                    else
                        echo "    No log file found"
                    fi
                    echo ""
                done
                echo "════════════════════════════════════════════════════════════"
            } >> "$LOG_FILE"
        else
            # For non-email imports, show simple list
            if [ ${#failed_items[@]} -le 5 ]; then
                for failed_item in "${failed_items[@]}"; do
                    log_message "ERROR" "  ${RED}✗${NC} $failed_item"
                done
            else
                log_message "ERROR" "  ${RED}✗${NC} ${#failed_items[@]} items failed (check log for details)"
            fi
        fi
    fi
}

# Import domain function
import_domain() {
    local domain=$1
    sudo -u zimbra /opt/zimbra/bin/zmprov cd "$domain" zimbraAuthMech zimbra >/dev/null 2>&1
    return $?
}

# Import user function
import_user() {
    local email=$1
    local givenName=$(grep givenName: ${BACKUP_DIR}/userdata/$email.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    local displayName=$(grep displayName: ${BACKUP_DIR}/userdata/$email.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    local shadowpass=$(cat ${BACKUP_DIR}/userpass/$email.shadow 2>/dev/null)
    # Generate secure temporary password
    local tmpPass=$(openssl rand -base64 12 2>/dev/null | tr -d "=+/" | cut -c1-12)
    if [ -z "$tmpPass" ] || [ ${#tmpPass} -lt 8 ]; then
        # Fallback if openssl is not available
        tmpPass=$(date +%s | sha256sum | base64 | head -c 12 | tr -d "=+/")
    fi
    # Ensure minimum length
    if [ ${#tmpPass} -lt 8 ]; then
        tmpPass="CHang*ksl9"
    fi
    
    if [ -z "$shadowpass" ]; then
        return 1
    fi
    
    # Create account
    sudo -u zimbra /opt/zimbra/bin/zmprov ca "$email" "${tmpPass}" cn "$givenName" displayName "$displayName" givenName "$givenName" >/dev/null 2>&1 || true
    # Set password
    sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" userPassword "$shadowpass" >/dev/null 2>&1
    return $?
}

# Import signature function
import_signature() {
    local email=$1
    local signature_file="${BACKUP_DIR}/signatures/$email.txt"
    
    if [ ! -e "$signature_file" ]; then
        return 0  # No signature file is not an error
    fi
    
    local FILESIZE=$(stat -c%s "$signature_file" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -eq 0 ]; then
        return 0
    fi
    
    local linei=0
    local SIGNATUREHTML="zimbraPrefMailSignatureHTML:"
    local SIGNATUREPLAIN="zimbraPrefMailSignature:"
    local SIGNATUREID="zimbraSignatureId:"
    local SIGNATURENAME="zimbraSignatureName:"
    local SIGNATURETYPE=""
    local SIGNATUREADD="0"
    
    while read -r LINE; do
        if [[ ${LINE} == *"${SIGNATUREHTML}"* ]]; then
            local zimbraPrefMailSignatureHTML=${LINE/zimbraPrefMailSignatureHTML:/}
            zimbraPrefMailSignatureHTML=`echo $zimbraPrefMailSignatureHTML | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`
            zimbraPrefMailSignatureHTML=${zimbraPrefMailSignatureHTML//\"/\\\"}
            SIGNATURETYPE="HTML"
            SIGNATUREADD="0"
            continue
        fi

        if [[ ${LINE} == *"${SIGNATUREPLAIN}"* ]]; then
            local zimbraPrefMailSignature=${LINE/zimbraPrefMailSignature:/}
            zimbraPrefMailSignature=`echo $zimbraPrefMailSignature | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`
            zimbraPrefMailSignature=${zimbraPrefMailSignature//\"/\\\"}
            SIGNATURETYPE="PLAIN"
            SIGNATUREADD="1"
            continue
        fi
    
        if [[ ${LINE} == *"${SIGNATUREID}"* ]]; then
            local zimbraSignatureId=${LINE/zimbraSignatureId:/}
            zimbraSignatureId=`echo $zimbraSignatureId | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'` 
            SIGNATUREADD="0"
            continue
        fi
      
        if [[ ${LINE} == *"${SIGNATURENAME}"* ]]; then
            local zimbraSignatureName=${LINE/zimbraSignatureName:/}
            zimbraSignatureName=`echo $zimbraSignatureName | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`   
            
            # Create the Signature First
            sudo -u zimbra /opt/zimbra/bin/zmprov csig "$email" "${zimbraSignatureName}" >/dev/null 2>&1

            # Add HTML Signature 
            if [[ ${SIGNATURETYPE} == "HTML" ]]; then     
                sudo -u zimbra /opt/zimbra/bin/zmprov msig "$email" "${zimbraSignatureName}" zimbraPrefMailSignatureHTML "${zimbraPrefMailSignatureHTML}" >/dev/null 2>&1
            fi
            
            if [[ ${SIGNATURETYPE} == "PLAIN" ]]; then  
                sudo -u zimbra /opt/zimbra/bin/zmprov msig "$email" "${zimbraSignatureName}" zimbraPrefMailSignature "${zimbraPrefMailSignature}" >/dev/null 2>&1
            fi

            SIGNATUREADD="0"
            SIGNATURETYPE="" 
            continue
        fi 

        if [[ ${SIGNATURETYPE} == "PLAIN" ]] && [[ ${SIGNATUREADD} -eq 1 ]]; then
            zimbraPrefMailSignature="${zimbraPrefMailSignature}
${LINE}"
        fi 
        ((linei=linei+1))
    done < "$signature_file"
    
    return 0
}

# Import autoresponder function
import_autoresponder() {
    local email=$1
    
    # Import reply
    if [ -e ${BACKUP_DIR}/autoresponders/${email}_reply.txt ]; then
        local FILESIZE=$(stat -c%s "${BACKUP_DIR}/autoresponders/${email}_reply.txt" 2>/dev/null || echo 0)
        if [ ${FILESIZE} -gt 38 ]; then
            tail -n +2 ${BACKUP_DIR}/autoresponders/${email}_reply.txt > /tmp/temp_${email}.txt 2>/dev/null
            sed '/zimbraPrefOutOfOfficeReply: /d' /tmp/temp_${email}.txt > /tmp/corrected_${email}.txt 2>/dev/null
            local AUTOREPLY1=$(</tmp/corrected_${email}.txt)
            sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraPrefOutOfOfficeReply "$AUTOREPLY1" >/dev/null 2>&1
            rm -f /tmp/temp_${email}.txt /tmp/corrected_${email}.txt 2>/dev/null
        fi
    fi

    # Import preferences
    if [ -e ${BACKUP_DIR}/autoresponders/$email.txt ]; then
        local FILESIZE=$(stat -c%s "${BACKUP_DIR}/autoresponders/$email.txt" 2>/dev/null || echo 0)
        if [ ${FILESIZE} -ne 0 ]; then
            local zimbraPrefOutOfOfficeReplyEnabled=$(grep zimbraPrefOutOfOfficeReplyEnabled: ${BACKUP_DIR}/autoresponders/$email.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$zimbraPrefOutOfOfficeReplyEnabled" ]; then
                sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraPrefOutOfOfficeReplyEnabled "$zimbraPrefOutOfOfficeReplyEnabled" >/dev/null 2>&1
            fi

            local zimbraFeatureOutOfOfficeReplyEnabled=$(grep zimbraFeatureOutOfOfficeReplyEnabled: ${BACKUP_DIR}/autoresponders/$email.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$zimbraFeatureOutOfOfficeReplyEnabled" ]; then
                sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraFeatureOutOfOfficeReplyEnabled "$zimbraFeatureOutOfOfficeReplyEnabled" >/dev/null 2>&1
            fi

            local zimbraPrefOutOfOfficeFromDate=$(grep zimbraPrefOutOfOfficeFromDate: ${BACKUP_DIR}/autoresponders/$email.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$zimbraPrefOutOfOfficeFromDate" ]; then
                sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraPrefOutOfOfficeFromDate "$zimbraPrefOutOfOfficeFromDate" >/dev/null 2>&1
            fi

            local zimbraPrefOutOfOfficeCacheDuration=$(grep zimbraPrefOutOfOfficeCacheDuration: ${BACKUP_DIR}/autoresponders/$email.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$zimbraPrefOutOfOfficeCacheDuration" ]; then
                sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraPrefOutOfOfficeCacheDuration "$zimbraPrefOutOfOfficeCacheDuration" >/dev/null 2>&1
            fi

            local zimbraPrefOutOfOfficeUntilDate=$(grep zimbraPrefOutOfOfficeUntilDate: ${BACKUP_DIR}/autoresponders/$email.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$zimbraPrefOutOfOfficeUntilDate" ]; then
                sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraPrefOutOfOfficeUntilDate "$zimbraPrefOutOfOfficeUntilDate" >/dev/null 2>&1
            fi

            local zimbraPrefOutOfOfficeStatusAlertOnLogin=$(grep zimbraPrefOutOfOfficeStatusAlertOnLogin: ${BACKUP_DIR}/autoresponders/$email.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$zimbraPrefOutOfOfficeStatusAlertOnLogin" ]; then
                sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraPrefOutOfOfficeStatusAlertOnLogin "$zimbraPrefOutOfOfficeStatusAlertOnLogin" >/dev/null 2>&1
            fi
        fi
    fi
    
    return 0
}

# Import filter function
import_filter() {
    local email=$1
    local filter_file="${BACKUP_DIR}/filters/$email.txt"
    
    if [ ! -e "$filter_file" ]; then
        return 0
    fi
    
    local FILESIZE=$(stat -c%s "$filter_file" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -le 20 ]; then
        return 0
    fi
    
    sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraMailSieveScript "`cat "$filter_file"`" >/dev/null 2>&1
    return $?
}

# Import contacts function
import_contacts() {
    local email=$1
    local contacts_file="${BACKUP_DIR}/contacts/$email.csv"
    
    if [ ! -e "$contacts_file" ]; then
        return 0
    fi
    
    local FILESIZE=$(stat -c%s "$contacts_file" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -le 25 ]; then
        return 0
    fi
    
    sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m "$email" pru /Contacts "$contacts_file" >/dev/null 2>&1
    return $?
}

# Import calendar function
import_calendar() {
    local email=$1
    
    if [ ! -d ${BACKUP_DIR}/calendar/$email ]; then
        return 0
    fi
    
    local success=0
    for calendar in ${BACKUP_DIR}/calendar/$email/*.tgz; do
        if [ -f "$calendar" ]; then
            local FILESIZE=$(stat -c%s "$calendar" 2>/dev/null || echo 0)
            if [ ${FILESIZE} -gt 0 ]; then
                sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m "$email" postRestURL "/?fmt=tgz&resolve=skip" "$calendar" >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    success=1
                fi
            fi
        fi
    done
    
    [ $success -eq 1 ] || return 0  # Return success even if no calendars
}

# Import briefcase function
import_briefcase() {
    local email=$1
    
    if [ ! -d ${BACKUP_DIR}/briefcase/$email ]; then
        return 0
    fi
    
    local success=0
    for briefcase in ${BACKUP_DIR}/briefcase/$email/*.tgz; do
        if [ -f "$briefcase" ]; then
            local FILESIZE=$(stat -c%s "$briefcase" 2>/dev/null || echo 0)
            if [ ${FILESIZE} -gt 0 ]; then
                sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m "$email" postRestURL "/?fmt=tgz&resolve=skip" "$briefcase" >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    success=1
                fi
            fi
        fi
    done
    
    [ $success -eq 1 ] || return 0  # Return success even if no briefcases
}

# Import forwarders function
import_forwarders() {
    local email=$1
    
    # Import hidden forwarders
    if [ -e ${BACKUP_DIR}/forwarders/${email}_hidden.txt ]; then
        local FILESIZE=$(stat -c%s "${BACKUP_DIR}/forwarders/${email}_hidden.txt" 2>/dev/null || echo 0)
        if [ ${FILESIZE} -gt 1 ]; then
            while read -r LINE; do
                if [[ ${LINE} == *"zimbraMailForwardingAddress:"* ]]; then
                    local zimbraMailForwardingAddress=${LINE/zimbraMailForwardingAddress:/}
                    zimbraMailForwardingAddress=`echo $zimbraMailForwardingAddress | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`  
                    sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" -zimbraMailForwardingAddress "${zimbraMailForwardingAddress}" >/dev/null 2>&1
                    sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" +zimbraMailForwardingAddress "${zimbraMailForwardingAddress}" >/dev/null 2>&1
                fi
            done < "${BACKUP_DIR}/forwarders/${email}_hidden.txt"
        fi
    fi  

    # Import user defined forwarders
    if [ -e ${BACKUP_DIR}/forwarders/${email}_userdefined.txt ]; then
        local FILESIZE=$(stat -c%s "${BACKUP_DIR}/forwarders/${email}_userdefined.txt" 2>/dev/null || echo 0)
        if [ ${FILESIZE} -gt 1 ]; then
            local zimbraPrefMailForwardingAddress=$(grep zimbraPrefMailForwardingAddress: ${BACKUP_DIR}/forwarders/${email}_userdefined.txt 2>/dev/null | cut -d ":" -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$zimbraPrefMailForwardingAddress" ]; then
                sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraPrefMailForwardingAddress "$zimbraPrefMailForwardingAddress" >/dev/null 2>&1
            fi
        fi
    fi
    
    return 0
}

# Import aliases function
import_aliases() {
    local email=$1
    
    if [ ! -e ${BACKUP_DIR}/alias/${email}.txt ]; then
        return 0
    fi
    
    local FILESIZE=$(stat -c%s "${BACKUP_DIR}/alias/${email}.txt" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -le 1 ]; then
        return 0
    fi
    
    while read -r LINE; do
        if [[ ${LINE} == *"zimbraMailAlias:"* ]]; then
            local zimbraMailAlias=${LINE/zimbraMailAlias:/}
            zimbraMailAlias=`echo $zimbraMailAlias | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`  
            sudo -u zimbra /opt/zimbra/bin/zmprov aaa "$email" "$zimbraMailAlias" >/dev/null 2>&1
        fi
    done < "${BACKUP_DIR}/alias/${email}.txt"
    
    return 0
}

# Import distribution list function
import_distribution_list() {
    local dist_list=$1
    
    if [ ! -e ${BACKUP_DIR}/distribution/${dist_list}.txt ]; then
        return 1
    fi
    
    local FILESIZE=$(stat -c%s "${BACKUP_DIR}/distribution/${dist_list}.txt" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -le 1 ]; then
        return 1
    fi
    
    # Create distribution list
    sudo -u zimbra /opt/zimbra/bin/zmprov CreateDistributionList "$dist_list" >/dev/null 2>&1 || true
    
    while read -r LINE; do
        if [[ ${LINE} == *"displayName:"* ]]; then
            local displayName=${LINE/displayName:/}
            displayName=`echo $displayName | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`
            displayName=${displayName//\"/\\\"}  
            sudo -u zimbra /opt/zimbra/bin/zmprov ModifyDistributionList "$dist_list" displayName "${displayName}" >/dev/null 2>&1
        fi

        if [[ ${LINE} == *"zimbraMailForwardingAddress:"* ]]; then
            local zimbraMailForwardingAddress=${LINE/zimbraMailForwardingAddress:/}
            zimbraMailForwardingAddress=`echo $zimbraMailForwardingAddress | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`  
            sudo -u zimbra /opt/zimbra/bin/zmprov AddDistributionListMember "$dist_list" "${zimbraMailForwardingAddress}" >/dev/null 2>&1
        fi
    done < "${BACKUP_DIR}/distribution/${dist_list}.txt"
    
    return 0
}

# Import preferences function
import_preferences() {
    local email=$1
    
    if [ ! -e ${BACKUP_DIR}/settings/${email}_prefs.txt ]; then
        return 0
    fi
    
    local FILESIZE=$(stat -c%s "${BACKUP_DIR}/settings/${email}_prefs.txt" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -le 20 ]; then
        return 0
    fi
    
    while read -r LINE; do
        for pref in "${IMPORT_PREF[@]}"; do 
            local REGEXPREF="${pref}:"
            if [[ ${LINE} == *"$REGEXPREF"* ]]; then
                local PREFVALUE=${LINE/$REGEXPREF/}
                PREFVALUE=`echo $PREFVALUE | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`
                if [[ $pref == "zimbraPrefMailTrustedSenderList" ]]; then
                    sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" +$pref "$PREFVALUE" >/dev/null 2>&1
                elif [[ $pref == "zimbraPrefHtmlEditorDefaultFontFamily" ]]; then
                    sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" $pref \""$PREFVALUE"\" >/dev/null 2>&1
                else 
                    sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" $pref "$PREFVALUE" >/dev/null 2>&1
                fi
            fi
        done
    done < "${BACKUP_DIR}/settings/${email}_prefs.txt"
    
    return 0
}

# Import legal intercepts function
import_legal_intercepts() {
    local email=$1
    
    if [ ! -e ${BACKUP_DIR}/settings/${email}_intercept.txt ]; then
        return 0
    fi
    
    local FILESIZE=$(stat -c%s "${BACKUP_DIR}/settings/${email}_intercept.txt" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -le 20 ]; then
        return 0
    fi
    
    while read -r LINE; do
        if [[ ${LINE} == *"zimbraInterceptAddress:"* ]]; then
            local intercept=${LINE/zimbraInterceptAddress:/}
            intercept=`echo $intercept | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`  
            sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraInterceptAddress "$intercept" >/dev/null 2>&1
        fi
    done < "${BACKUP_DIR}/settings/${email}_intercept.txt"
    
    return 0
}

# Import share settings function
import_share_settings() {
    local email=$1
    
    if [ ! -e ${BACKUP_DIR}/settings/${email}_shared.txt ]; then
        return 0
    fi
    
    local FILESIZE=$(stat -c%s "${BACKUP_DIR}/settings/${email}_shared.txt" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -le 25 ]; then
        return 0
    fi
    
    while read -r LINE; do
        if [[ ${LINE} == *"zimbraSharedItem:"* ]]; then
            local exploded=`sed 's/;/\n/g' <<< "${LINE}"`
            local shareType=""
            local shareGrantee=""
            local shareFolder=""
            local shareRights=""
            local shareGranteeType=""
            
            while read -r SHARELINE; do 
                if [[ ${SHARELINE} == *"zimbraSharedItem:"* ]]; then
                    shareType=""
                    shareGrantee=""
                    shareFolder=""
                    shareRights=""
                    shareGranteeType=""
                fi

                if [[ ${SHARELINE} == *"folderDefaultView:"* ]]; then
                    shareType=${SHARELINE/folderDefaultView:/}
                    shareType=`echo $shareType | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`
                fi

                if [[ ${SHARELINE} == *"granteeName:"* ]]; then
                    shareGrantee=${SHARELINE/granteeName:/}
                    shareGrantee=`echo $shareGrantee | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`
                fi

                if [[ ${SHARELINE} == *"granteeType:"* ]]; then
                    shareGranteeType=${SHARELINE/granteeType:/}
                    shareGranteeType=`echo $shareGranteeType | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`
                fi

                if [[ ${SHARELINE} == *"folderPath:"* ]]; then
                    shareFolder=`echo ${SHARELINE} | cut -d ":" -f2`
                fi

                if [[ ${SHARELINE} == *"rights:"* ]]; then
                    shareRights=${SHARELINE/rights:/}
                    shareRights=`echo $shareRights | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`
                fi

                if [[ -n "$shareRights" && -n "$shareFolder" && -n "$shareGrantee" && -n "$shareGranteeType" ]]; then 
                    if [[ $shareGranteeType == "usr" ]]; then
                        sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m "$email" mfg "${shareFolder}" account "$shareGrantee" "$shareRights" >/dev/null 2>&1
                    fi
                    shareType=""
                    shareGrantee=""
                    shareFolder=""
                    shareRights=""
                    shareGranteeType=""  
                fi 
            done <<< "$exploded"
        fi
    done < "${BACKUP_DIR}/settings/${email}_shared.txt"
    
    return 0
}

# Import user status function
import_user_status() {
    local email=$1
    
    if [ ! -e ${BACKUP_DIR}/settings/${email}_status.txt ]; then
        return 0
    fi
    
    local FILESIZE=$(stat -c%s "${BACKUP_DIR}/settings/${email}_status.txt" 2>/dev/null || echo 0)
    if [ ${FILESIZE} -le 10 ]; then
        return 0
    fi
    
    while read -r LINE; do
        if [[ ${LINE} == *"zimbraAccountStatus:"* ]]; then
            local status=${LINE/zimbraAccountStatus:/}
            status=`echo $status | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'`  
            sudo -u zimbra /opt/zimbra/bin/zmprov ma "$email" zimbraAccountStatus "$status" >/dev/null 2>&1
        fi
    done < "${BACKUP_DIR}/settings/${email}_status.txt"
    
    return 0
}

# Import email function for imapsync (silent - no output to screen)
import_email_imapsync() {
    local email=$1
    export LC_ALL="en_US.UTF-8"
    
    # Check if user exists on destination server
    if ! sudo -u zimbra /opt/zimbra/bin/zmprov ga "$email" >/dev/null 2>&1; then
        return 1
    fi
    
    # Create imapsync log directory
    local imapsync_log_dir="${BACKUP_DIR}/imapsync_logs"
    if [ ! -d "$imapsync_log_dir" ]; then
        mkdir -p "$imapsync_log_dir"
        chown -R zimbra:zimbra "$imapsync_log_dir"
    fi
    
    local log_file="${imapsync_log_dir}/${email}.log"
    local max_retries=3
    local retry=0
    local result=1
    
    while [ $retry -lt $max_retries ]; do
        # Run imapsync completely silently - no output to screen
        imapsync \
            --addheader \
            --errorsmax 100000 \
            --nosyncacls \
            --subscribe \
            --syncinternaldates \
            --nofoldersizes \
            --skipsize \
            --timeout 120 \
            --timeout1 120 \
            --timeout2 120 \
            --host1 ${OLD_SERVER_IP} \
            --ssl1 \
            --user1 "$email" \
            --authuser1 ${OLD_ADMIN_USER} \
            --password1 ${OLD_ADMIN_PASSWORD} \
            --host2 ${NEW_SERVER_IP} \
            --ssl2 \
            --user2 "$email" \
            --authuser2 ${NEW_ADMIN_USER} \
            --password2 ${NEW_ADMIN_PASSWORD} \
            --noauthmd5 \
            --sep1 / \
            --prefix1 / \
            --sep2 / \
            --prefix2 "" \
            --regexflag "s/:FLAG/_FLAG/g" \
            --exclude "Chats" \
            --logfile "$log_file" >/dev/null 2>&1
        
        result=$?
        
        # Wait a moment for log file to be fully written
        sleep 1
        
        # Check log file for completion status
        if [ -f "$log_file" ] && [ -s "$log_file" ]; then
            # Check if imapsync completed successfully
            local exit_msg=$(grep -i "Exiting with return value" "$log_file" 2>/dev/null | tail -1)
            
            if [ -n "$exit_msg" ] || [ $result -eq 0 ]; then
                # Success - break retry loop
                break
            else
                # Failed - retry if attempts remaining
                retry=$((retry + 1))
                if [ $retry -lt $max_retries ]; then
                    sleep 10
                fi
            fi
        else
            # Log file doesn't exist or is empty - retry if attempts remaining
            retry=$((retry + 1))
            if [ $retry -lt $max_retries ]; then
                sleep 10
            fi
        fi
    done
    
    return $result
}

# Function to run email import
run_email_import() {
    if command -v imapsync > /dev/null 2>&1; then
        # Check imapsync version
        IMAPSYNC_VERSION=$(imapsync --version 2>&1 | head -1)
        log_message "INFO" "imapsync version: $IMAPSYNC_VERSION"
        
        # Get old server IP address for imapsync
        if [ -z "$OLD_SERVER_IP" ]; then
            # Check if SOURCE is a valid IP (not --email-only or empty)
            if [ -n "$SOURCE" ] && [ "$SOURCE" != "" ] && [ "$SOURCE" != "--email-only" ] && [[ ! "$SOURCE" =~ ^-- ]]; then
                read -p "Please Enter Old Server IP Address for imapsync [default: ${SOURCE}]: " OLD_SERVER_IP
                if [ -z "$OLD_SERVER_IP" ]; then
                    OLD_SERVER_IP="$SOURCE"
                fi
            else
                read -p "Please Enter Old Server IP Address for imapsync: " OLD_SERVER_IP
            fi
            echo ""
        fi
        
        # Get new server IP address for imapsync
        if [ -z "$NEW_SERVER_IP" ]; then
            read -p "Please Enter New Server IP Address for imapsync [default: localhost]: " NEW_SERVER_IP
            if [ -z "$NEW_SERVER_IP" ]; then
                NEW_SERVER_IP="localhost"
            fi
            echo ""
        fi
        
        # Get old server admin credentials
        if [ -z "$OLD_ADMIN_USER" ] || [ -z "$OLD_ADMIN_PASSWORD" ]; then
            read -p "Please Enter Admin Username for the Old Server: " OLD_ADMIN_USER
            read -s -p "Please Enter Admin Password for the Old Server: " OLD_ADMIN_PASSWORD
            echo ""
        fi
        
        # Get new server admin credentials
        if [ -z "$NEW_ADMIN_USER" ] || [ -z "$NEW_ADMIN_PASSWORD" ]; then
            read -p "Please Enter Admin Username for the New Server: " NEW_ADMIN_USER
            read -s -p "Please Enter Admin Password for the New Server: " NEW_ADMIN_PASSWORD
            echo ""
        fi
        
        # Import emails with progress (parallel processing - 10 concurrent jobs)
        import_with_resume_parallel "Emails" import_email_imapsync "${BACKUP_DIR}/emails.txt" 10
        
        # Clear passwords from memory
        OLD_ADMIN_PASSWORD=""
        NEW_ADMIN_PASSWORD=""
        OLD_ADMIN_USER=""
        NEW_ADMIN_USER=""
        OLD_SERVER_IP=""
        NEW_SERVER_IP=""
    else
        log_message "ERROR" "${RED}imapsync does not exist. Exiting....${NC}"
        exit 1
    fi
}

# Main script starts here
sudo -u zimbra bash -c 'export LC_ALL="en_US.UTF-8"'
export LC_ALL="en_US.UTF-8"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Zimbra Import Script${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Check arguments
if [ -z "$1" ]; then
    echo -e "${RED}Usage:${NC} ./import_zimbra.sh <source_server_ip> [backup_directory] [--email-only]"
    echo "Example: ./import_zimbra.sh 111.222.333.444 /opt/zmbackup"
    echo "Example: ./import_zimbra.sh 111.222.333.444"
    echo "Example: ./import_zimbra.sh 111.222.333.444 /opt/zmbackup --email-only"
    echo ""
    echo "Options:"
    echo "  --email-only    Run only email import (imapsync) step - useful for syncing new emails"
    echo ""
    echo "Hostnames can be used in lieu of IP addresses but do so with caution."
    echo "Assumes that you have root access to the source server. Run this as root."
    echo "It is suggested that you use screen in case the connection gets broken."
    echo "Please make sure that imapsync is installed - otherwise the copying of emails will not work."
    exit 1
fi

# Check for email-only mode
EMAIL_ONLY_MODE=0
if [ "$2" = "--email-only" ] || [ "$3" = "--email-only" ]; then
    EMAIL_ONLY_MODE=1
fi

SOURCE=$1
if [ "$2" == "--email-only" ]; then
    SOURCE_DIR=${BACKUP_DIR}
elif [ -z "$2" ]; then
    SOURCE_DIR=${BACKUP_DIR}
else 
    TRIMMED=${2%/}
    SOURCE_DIR=${TRIMMED}
fi

echo -e "${CYAN}Source Server:${NC} ${SOURCE}"
echo -e "${CYAN}Source Directory:${NC} ${SOURCE_DIR}"
echo -e "${CYAN}Target Directory:${NC} ${BACKUP_DIR}"
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
LOG_FILE="${BACKUP_DIR}/import.log"
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
        echo -e "${YELLOW}Previous import session detected!${NC}"
        echo -e "Last progress: ${CYAN}$last_step${NC} - $last_progress/$last_total"
        echo ""
        echo -n "Resume from where you left off? (y/n): "
        read RESPONSE_VAR
        if [ "${RESPONSE_VAR}" != "y" ]; then
            echo "Starting fresh import..."
            rm -f ${STATE_DIR}/*_completed.txt 2>/dev/null
            rm -f "$PROGRESS_FILE" 2>/dev/null
        else
            echo -e "${GREEN}Resuming previous import...${NC}"
        fi
    else
        echo -e "${CYAN}Import will be saved to: ${BACKUP_DIR}${NC}"
        echo -n "Proceed with import? (y/n): "
        read RESPONSE_VAR
        if [ "${RESPONSE_VAR}" != "y" ]; then
            echo "Import cancelled."
            exit 0
        fi
    fi
else
    echo -e "${CYAN}Import will be saved to: ${BACKUP_DIR}${NC}"
    echo -n "Proceed with import? (y/n): "
    read RESPONSE_VAR
    if [ "${RESPONSE_VAR}" != "y" ]; then
        echo "Import cancelled."
        exit 0
    fi
fi

echo ""
START_TIME=$(date +%s)

# Email-only mode: Skip all steps except email import
if [ "$EMAIL_ONLY_MODE" -eq 1 ]; then
    echo -e "${YELLOW}Email-only mode enabled. Skipping all steps except email import.${NC}"
    echo ""
    
    # Check required files
    if [ ! -e ${BACKUP_DIR}/emails.txt ]; then
        log_message "ERROR" "${RED}${BACKUP_DIR}/emails.txt does not exist${NC}"
        exit 1
    fi
    
    TOTAL_USERS=$(wc -l < ${BACKUP_DIR}/emails.txt 2>/dev/null || echo "0")
    log_message "INFO" "${GREEN}✓ Found ${CYAN}$TOTAL_USERS${NC} users to sync emails"
    echo ""
    
    # Run email import directly
    echo -e "${BLUE}Email Import (imapsync)${NC}"
    run_email_import
    
    # Final summary
    END_TIME=$(date +%s)
    TOTAL_TIME=$((END_TIME - START_TIME))
    TOTAL_TIME_STR=$(printf '%02d:%02d:%02d' $((TOTAL_TIME/3600)) $((TOTAL_TIME%3600/60)) $((TOTAL_TIME%60)))
    
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}Email sync completed!${NC}"
    echo -e "Total time: ${CYAN}$TOTAL_TIME_STR${NC}"
    echo -e "Log file: ${CYAN}${LOG_FILE}${NC}"
    echo -e "${CYAN}========================================${NC}"
    exit 0
fi

# Normal import mode: Full import process
# Sync data from source
echo -e "${BLUE}Step 1: Syncing Data from Source${NC}"
if [ ! -f "${BACKUP_DIR}/.sync_completed" ]; then
    log_message "INFO" "Starting rsync from ${SOURCE}:${SOURCE_DIR}/ to ${BACKUP_DIR}/"
    rsync -azlgop --progress root@${SOURCE}:${SOURCE_DIR}/ ${BACKUP_DIR}/ 2>&1 | tee -a "$LOG_FILE"
    if [ $? -eq 0 ]; then
        touch "${BACKUP_DIR}/.sync_completed"
        log_message "INFO" "${GREEN}✓ Data sync completed${NC}"
    else
        log_message "ERROR" "${RED}Data sync failed${NC}"
        exit 1
    fi
else
    log_message "INFO" "${GREEN}✓ Data already synced${NC}"
fi

# Check required files
if [ ! -e ${BACKUP_DIR}/domains.txt ]; then
    log_message "ERROR" "${RED}${BACKUP_DIR}/domains.txt does not exist${NC}"
    exit 1
fi

if [ ! -e ${BACKUP_DIR}/emails.txt ]; then
    log_message "ERROR" "${RED}${BACKUP_DIR}/emails.txt does not exist${NC}"
    exit 1
fi

TOTAL_USERS=$(wc -l < ${BACKUP_DIR}/emails.txt 2>/dev/null || echo "0")
DOMAIN_COUNT=$(wc -l < ${BACKUP_DIR}/domains.txt 2>/dev/null || echo "0")
log_message "INFO" "${GREEN}✓ Found ${CYAN}$TOTAL_USERS${NC} users across ${CYAN}$DOMAIN_COUNT${NC} domain(s)"
echo ""

# Import domains
echo -e "${BLUE}Step 2: Importing Domains${NC}"
echo -n "Import domains? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Domains" import_domain "${BACKUP_DIR}/domains.txt"
    log_message "INFO" "Current Domain List:"
    sudo -u zimbra /opt/zimbra/bin/zmprov gad 2>/dev/null | head -20
fi

# Import users
echo -e "${BLUE}Step 3: Importing Users${NC}"
echo -n "Import users? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Users" import_user "${BACKUP_DIR}/emails.txt"
    log_message "INFO" "Current User List (first 20):"
    sudo -u zimbra /opt/zimbra/bin/zmprov -l gaa 2>/dev/null | head -20
fi

# Import signatures and autoresponders
echo -e "${BLUE}Step 4: Importing Signatures and Autoresponders${NC}"
echo -n "Import signatures and autoresponders? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Signatures" import_signature "${BACKUP_DIR}/emails.txt"
    import_with_resume "Autoresponders" import_autoresponder "${BACKUP_DIR}/emails.txt"
fi

# Import filters
echo -e "${BLUE}Step 5: Importing Filters${NC}"
echo -n "Import filters? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Filters" import_filter "${BACKUP_DIR}/emails.txt"
fi

# Import contacts
echo -e "${BLUE}Step 6: Importing Contacts${NC}"
echo -n "Import contacts? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Contacts" import_contacts "${BACKUP_DIR}/emails.txt"
fi

# Import calendars
echo -e "${BLUE}Step 7: Importing Calendars${NC}"
echo -n "Import calendars? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Calendars" import_calendar "${BACKUP_DIR}/emails.txt"
fi

# Import briefcase
echo -e "${BLUE}Step 8: Importing Briefcase${NC}"
echo -n "Import briefcase? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Briefcase" import_briefcase "${BACKUP_DIR}/emails.txt"
fi

# Import forwarders
echo -e "${BLUE}Step 9: Importing Forwarders${NC}"
echo -n "Import forwarders? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Forwarders" import_forwarders "${BACKUP_DIR}/emails.txt"
fi

# Import aliases
echo -e "${BLUE}Step 10: Importing Aliases${NC}"
echo -n "Import aliases? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Aliases" import_aliases "${BACKUP_DIR}/emails.txt"
fi

# Import distribution lists
echo -e "${BLUE}Step 11: Importing Distribution Lists${NC}"
echo -n "Import distribution lists? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    if [ -f "${BACKUP_DIR}/distribution_list.txt" ] && [ -s "${BACKUP_DIR}/distribution_list.txt" ]; then
        import_with_resume "DistLists" import_distribution_list "${BACKUP_DIR}/distribution_list.txt"
    else
        log_message "INFO" "${GREEN}✓ No distribution lists found${NC}"
    fi
fi

# Import emails (imapsync)
echo -e "${BLUE}Step 12: Importing Emails (imapsync)${NC}"
echo -e "${YELLOW}WARNING: This could take a long time. Use screen to avoid disconnection problems.${NC}"
echo -n "Import emails? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    run_email_import
fi

# Import preferences
echo -e "${BLUE}Step 13: Importing Preferences${NC}"
echo -n "Import preferences? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "Preferences" import_preferences "${BACKUP_DIR}/emails.txt"
fi

# Import legal intercepts
echo -e "${BLUE}Step 14: Importing Legal Intercepts${NC}"
echo -n "Import legal intercepts? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "LegalIntercepts" import_legal_intercepts "${BACKUP_DIR}/emails.txt"
fi

# Import share settings
echo -e "${BLUE}Step 15: Importing Share Settings${NC}"
echo -n "Import share settings? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "ShareSettings" import_share_settings "${BACKUP_DIR}/emails.txt"
fi

# Import user status
echo -e "${BLUE}Step 16: Importing User Status${NC}"
echo -n "Import user status? (y/n): "
read RESPONSE_VAR
if [ "${RESPONSE_VAR}" == "y" ]; then
    import_with_resume "UserStatus" import_user_status "${BACKUP_DIR}/emails.txt"
fi

# Final summary
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_TIME_STR=$(printf '%02d:%02d:%02d' $((TOTAL_TIME/3600)) $((TOTAL_TIME%3600/60)) $((TOTAL_TIME%60)))

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}Import completed successfully!${NC}"
echo -e "Total time: ${CYAN}$TOTAL_TIME_STR${NC}"
echo -e "Backup directory: ${CYAN}${BACKUP_DIR}${NC}"
echo -e "Log file: ${CYAN}${LOG_FILE}${NC}"
echo -e "${CYAN}========================================${NC}"

# Offer to sync emails again (for new emails that arrived during migration)
if command -v imapsync > /dev/null 2>&1; then
    echo ""
    echo -e "${YELLOW}Note:${NC} If new emails arrived on the old server during migration,"
    echo -e "you can sync them again now."
    echo ""
    echo -n "Do you want to sync emails again (to catch any new emails)? (y/n): "
    read RESPONSE_VAR
    if [ "${RESPONSE_VAR}" == "y" ]; then
        echo ""
        echo -e "${BLUE}Re-syncing Emails (imapsync)${NC}"
        START_TIME=$(date +%s)
        run_email_import
        
        END_TIME=$(date +%s)
        SYNC_TIME=$((END_TIME - START_TIME))
        SYNC_TIME_STR=$(printf '%02d:%02d:%02d' $((SYNC_TIME/3600)) $((SYNC_TIME%3600/60)) $((SYNC_TIME%60)))
        
        echo ""
        echo -e "${GREEN}Email re-sync completed!${NC}"
        echo -e "Sync time: ${CYAN}$SYNC_TIME_STR${NC}"
    fi
fi
