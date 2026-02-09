#!/bin/bash
#
# Checks prerequisites for miuOps deployment
#

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Fun icons
SUCCESS="🚀"
WARNING="⚠️"
ERROR="❌"
INFO="💡"
ROCKET="🚀"
WRENCH="🔧"
CLOUD="☁️"
SECURE="🔒"
CHECK="✅"

echo -e "\n${BOLD}${PURPLE}======================================${NC}"
echo -e "${BOLD}${PURPLE}  miuOps DEPLOYMENT READINESS CHECK ${NC}"
echo -e "${BOLD}${PURPLE}======================================${NC}\n"

echo -e "${BLUE}${ROCKET} Let's make sure your system is ready for an epic deployment!${NC}\n"

# Display progress function
progress() {
  echo -e "${CYAN}${WRENCH} Checking $1...${NC}"
  sleep 0.5
}

# Check Ansible version
progress "Ansible installation"
if command -v ansible >/dev/null 2>&1; then
    # Use a different approach to get version to avoid broken pipe
    ansible_version=$(ansible --version 2>/dev/null | head -n1 | cut -d' ' -f2)
    required_version="2.10.0"
    
    if [[ -n "$ansible_version" ]]; then
        if [ "$(printf '%s\n' "$required_version" "$ansible_version" | sort -V | head -n1)" = "$required_version" ]; then
            echo -e "  ${GREEN}${SUCCESS} Ansible ${BOLD}v${ansible_version}${NC}${GREEN} detected - Perfect!${NC}"
        else
            echo -e "  ${RED}${ERROR} Ansible version ${BOLD}${ansible_version}${NC}${RED} found - You need version ${BOLD}2.10.0+${NC}${RED} for smooth sailing${NC}"
        fi
    else
        echo -e "  ${YELLOW}${WARNING} Ansible is installed but couldn't determine its version - Let's hope it's compatible!${NC}"
    fi
else
    echo -e "  ${RED}${ERROR} Ansible not found. Please install Ansible 2.10.0+ to continue your journey${NC}"
fi

echo ""

# Check Docker (optional)
progress "Docker installation"
if command -v docker >/dev/null 2>&1; then
    docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
    echo -e "  ${GREEN}${SUCCESS} Docker ${BOLD}v${docker_version}${NC}${GREEN} ready to create containers!${NC}"
else 
    echo -e "  ${BLUE}${INFO} Docker not found locally - No worries! It will be installed on your target servers${NC}"
fi

echo ""

# Check if inventory.ini exists
progress "Configuration files"
if [ -f "inventory.ini" ]; then
    echo -e "  ${GREEN}${CHECK} inventory.ini ${BOLD}found${NC}${GREEN} and ready to go${NC}"
else
    echo -e "  ${RED}${ERROR} inventory.ini not found. Create it by running:${NC}"
    echo -e "  ${BOLD}cp inventory.ini.template inventory.ini${NC}"
fi

# Check if group_vars/all.yml exists
if [ -f "group_vars/all.yml" ]; then
    echo -e "  ${GREEN}${CHECK} group_vars/all.yml ${BOLD}found${NC}${GREEN} and ready for action${NC}"
else
    echo -e "  ${RED}${ERROR} group_vars/all.yml not found. Create it by running:${NC}"
    echo -e "  ${BOLD}cp group_vars/all.yml.template group_vars/all.yml${NC}"
fi

echo -e "\n${BLUE}${CLOUD} Dreaming of automated infrastructure...${NC}"
sleep 0.5

echo -e "\n${BOLD}${PURPLE}======================================${NC}"
echo -e "${BOLD}${GREEN}  ${SECURE} DEPLOYMENT READINESS SUMMARY ${SECURE}  ${NC}"
echo -e "${BOLD}${PURPLE}======================================${NC}\n"

# Count issues
issues=0
if ! command -v ansible >/dev/null 2>&1; then
    issues=$((issues+1))
fi
if [ ! -f "inventory.ini" ]; then
    issues=$((issues+1))
fi
if [ ! -f "group_vars/all.yml" ]; then
    issues=$((issues+1))
fi

# Display result
if [ $issues -eq 0 ]; then
    echo -e "${GREEN}${BOLD}${ROCKET} All systems GO! You're ready to deploy your infrastructure!${NC}"
    echo -e "${GREEN}Run ${BOLD}ansible-playbook playbook.yml${NC}${GREEN} to start your journey.${NC}"
elif [ $issues -eq 1 ]; then
    echo -e "${YELLOW}${BOLD}${WARNING} Almost there! Fix the issue above and you'll be ready to launch.${NC}"
else
    echo -e "${YELLOW}${BOLD}${WARNING} Found ${issues} items to fix before you can deploy.${NC}"
    echo -e "${YELLOW}Address the issues above and run this check again.${NC}"
fi

echo -e "\n${CYAN}Happy deploying! ${ROCKET}${NC}\n" 