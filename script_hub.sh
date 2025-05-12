#!/bin/bash

# Colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to check if a tool is installed
check_tool() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}$1 is not installed.${NC}"
        echo -e "Installing $1 with Homebrew..."
        
        if ! command -v brew &> /dev/null; then
            echo -e "${RED}Homebrew is not installed. Please install Homebrew first.${NC}"
            echo "Visit https://brew.sh/ for installation instructions."
            exit 1
        fi
        
        brew install $1
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to install $1. Please install it manually.${NC}"
            exit 1
        else
            echo -e "${GREEN}$1 has been successfully installed.${NC}"
        fi
    else
        echo -e "${GREEN}$1 is already installed.${NC}"
    fi
}

# Function to run SwiftFormat
run_swiftformat() {
    echo -e "${YELLOW}Running SwiftFormat...${NC}"
    swiftformat . --config .swiftformat
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SwiftFormat completed successfully.${NC}"
    else
        echo -e "${RED}SwiftFormat failed.${NC}"
        exit 1
    fi
}

# Function to run SwiftLint
run_swiftlint() {
    echo -e "${YELLOW}Running SwiftLint...${NC}"
    swiftlint --config .swiftlint.yml
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SwiftLint completed successfully.${NC}"
    else
        echo -e "${RED}SwiftLint found issues. Please fix them according to the output above.${NC}"
    fi
}

# Main menu
main_menu() {
    echo -e "${YELLOW}Swift Code Quality Tools${NC}"
    echo "1. Run SwiftFormat (format Swift code)"
    echo "2. Run SwiftLint (lint Swift code)"
    echo "3. Run both tools"
    echo "4. Exit"
    echo -n "Select an option (1-4): "
    read option
    
    case $option in
        1) 
            check_tool "swiftformat"
            run_swiftformat
            ;;
        2) 
            check_tool "swiftlint"
            run_swiftlint
            ;;
        3) 
            check_tool "swiftformat"
            check_tool "swiftlint"
            run_swiftformat
            run_swiftlint
            ;;
        4) 
            echo "Exiting..."
            exit 0
            ;;
        *) 
            echo -e "${RED}Invalid option. Please try again.${NC}"
            main_menu
            ;;
    esac
}

# Start the script
main_menu 