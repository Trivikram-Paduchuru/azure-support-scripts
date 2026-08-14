#!/bin/bash

set -euo pipefail

METADATA_URL="http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
HEADER="Metadata:true"
RHUI_HOST="rhui4-1.microsoft.com"

#--------------------------------------------------
# UI Helpers
#--------------------------------------------------
line() { echo "--------------------------------------------------"; }
section() { echo; echo "[ $1 ]"; }
info() { echo "➜  $1"; }
ok() { echo "✔  $1"; }
warn() { echo "⚠  $1"; }
fail() { echo "✖  $1"; exit 1; }

#--------------------------------------------------
# Helper: Package Manager
#--------------------------------------------------
pkg_mgr() {
    if [[ "$OS_VERSION" -ge 8 ]]; then
        echo "dnf"
    else
        echo "yum"
    fi
}

#--------------------------------------------------
# Helper: Repo Query
#--------------------------------------------------
repo_query() {
    if [[ "$OS_VERSION" -ge 8 ]]; then
        dnf repoquery --config "$1" --qf "$2" "$3" 2>/dev/null || true
    else
        repoquery --config "$1" --qf "$2" "$3" 2>/dev/null || true
    fi
}

#--------------------------------------------------
# Helper: RHUI Installation Failure Guidance
#--------------------------------------------------
show_rhui_failure_guidance() {
    local article_url="https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/linux/linux-rhui-connectivity-issues"
    local validation_script_url="https://raw.githubusercontent.com/Azure/azure-support-scripts/refs/heads/master/Linux_scripts/rhui-check/rhui-check.py"

    echo    
    warn "Review the Microsoft RHUI connectivity troubleshooting steps:"
    echo "$article_url"
    echo
    warn "Recommended: Run the RHUI validation script for RHEL $OS_VERSION."

    case "$OS_VERSION" in
        7)
            echo "curl -sL $validation_script_url | sudo python2 -"
            ;;
        8|9|10)
            echo "curl -sL $validation_script_url | sudo python3 -"
            echo
            info "If python3 is unavailable, use:"
            echo "curl -sL $validation_script_url | sudo /usr/libexec/platform-python -"
            ;;
        *)
            warn "No OS-specific validation command is documented for RHEL $OS_VERSION."
            info "Follow the Microsoft article for currently supported versions."
            ;;
    esac

    echo
    info "After running the Microsoft rhui-check.py command above,"
    info "its diagnostic results are saved to /var/log/rhuicheck.log."
    info "This validation script is intended for RHEL Marketplace PAYG images."
    info "For custom images, its results may not cover every configuration issue."    
}

#--------------------------------------------------
# Helper: Custom Image Type Selection
#--------------------------------------------------
select_custom_image_type() {
    echo "Available Image Types"
    echo
    echo "1) Standard"
    echo "2) SAP Apps"
    echo "3) SAP HA"
    echo "4) HA"
    echo

    read -rp "Enter choice [1-4]: " IMAGE_CHOICE

    case "$IMAGE_CHOICE" in
        1)
            IMAGE_SUFFIX="standard"
            ;;
        2)
            IMAGE_SUFFIX="sapapps"
            ;;
        3)
            IMAGE_SUFFIX="sap-ha"
            ;;
        4)
            IMAGE_SUFFIX="ha"
            ;;
        *)
            fail "Invalid image type selection"
            ;;
    esac

    ok "Selected Image Type : $IMAGE_SUFFIX"
}

#--------------------------------------------------
# 1. OS Details
#--------------------------------------------------
section "Detecting Operating System"

[ -f /etc/os-release ] || fail "OS detection failed"

source /etc/os-release

OS_VERSION=$(echo "$VERSION_ID" | cut -d '.' -f1)
OS_MINOR=$(echo "${VERSION_ID#*.}" | cut -d '.' -f1)
OS_MINOR=${OS_MINOR:-0}

ok "OS        : $PRETTY_NAME"
ok "Version   : $OS_VERSION"
ok "Minor     : $OS_MINOR"

#--------------------------------------------------
# Last Supported Minor Version Detection
#--------------------------------------------------
LAST_MINOR_RELEASE=0

# RHEL 7  -> 7.9
# RHEL 8+ -> x.10

if [[ "$OS_VERSION" == "7" && "$OS_MINOR" == "9" ]]; then
    LAST_MINOR_RELEASE=1
elif [[ "$OS_VERSION" -ge 8 && "$OS_MINOR" == "10" ]]; then
    LAST_MINOR_RELEASE=1
fi

#--------------------------------------------------
# 2. RHUI Check
#--------------------------------------------------
section "Checking Existing RHUI"

RHUI_INSTALLED=$(rpm -qa | grep -i rhui || true)

if [[ -n "$RHUI_INSTALLED" ]]; then
    warn "RHUI already installed"
    echo "$RHUI_INSTALLED"
    exit 0
fi

ok "RHUI not present"

METADATA=$(curl -s -H "$HEADER" "$METADATA_URL") || fail "Metadata fetch failed"

OFFER=$(echo "$METADATA" | grep -oP '"offer":\s*"\K[^"]*' | head -1 || true)
SKU=$(echo "$METADATA" | grep -oP '"sku":\s*"\K[^"]*' | head -1 || true)
IMAGE_REFERENCE_ID=$(echo "$METADATA" |
    grep -oP '"imageReference"\s*:\s*\{[^}]*\}' |
    grep -oP '"id"\s*:\s*"\K[^"]*' |
    head -1 || true)

#--------------------------------------------------
# 3. Detect Image Type
#--------------------------------------------------
section "Detecting Image Type"

if [[ -n "$OFFER" && -n "$SKU" && -z "$IMAGE_REFERENCE_ID" ]]; then
    OS_CREATED_FROM="Platform Image"
    IMAGE_CLASSIFICATION="Marketplace image"
else
    OS_CREATED_FROM=${IMAGE_REFERENCE_ID:-"Non-Platform Image"}
    IMAGE_CLASSIFICATION="Custom image"
fi

ok "OS created from      : $OS_CREATED_FROM"
ok "Image classification : $IMAGE_CLASSIFICATION"

#--------------------------------------------------
# 4. Azure Metadata
#--------------------------------------------------
section "Azure Metadata"

info "Offer : ${OFFER:-<empty>}"
info "SKU   : ${SKU:-<empty>}"

section "Select Billing Model"

echo "Available Billing Models"
echo
echo "1) PAYG (Pay-As-You-Go)"
echo "2) BYOS (Bring Your Own Subscription)"
echo

read -rp "Enter choice [1-2]: " BILLING_CHOICE

case "$BILLING_CHOICE" in
    1)
        BILLING_MODEL="PAYG"
        ;;
    2)
        BILLING_MODEL="BYOS"
        ;;
    *)
        fail "Invalid billing model selection"
        ;;
esac

ok "Billing Model : $BILLING_MODEL"

if [[ "$BILLING_MODEL" == "BYOS" ]]; then
    echo
    line

    echo "BYOS (Bring Your Own Subscription) selected."
    echo
    echo "RHUI repositories are not intended for BYOS systems."
    echo
    echo "Please register the system using subscription-manager"
    echo "and connect it to Red Hat CDN or your Satellite server."
    echo
    echo "https://access.redhat.com/solutions/253273"
    echo
    echo "RHUI installation is not applicable for BYOS systems."

    line
    echo
    exit 0
fi

if [[ "$IMAGE_CLASSIFICATION" == "Custom image" ]]; then

    section "Select Image Type"

    
    warn "Custom image detected. Select the correct image type."
    warn "This choice determines which RHUI repositories and packages are installed."
    warn "An incorrect selection may cause repository or package compatibility issues."    
    echo

    select_custom_image_type

    section "Validating Selected Image Type"

    INSTALLED_PACKAGE_NAMES=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null) || fail "Unable to query installed packages"
    SAP_PACKAGES=""
    HA_PACKAGES=""

    while IFS= read -r PACKAGE_NAME; do
        case "$PACKAGE_NAME" in
            sapconf|sapconf-*|tuned-profiles-sap|tuned-profiles-sap-*|compat-sap|compat-sap-*|resource-agents-sap|resource-agents-sap-*|rhel-system-roles-sap|rhel-system-roles-sap-*)
                SAP_PACKAGES+="${SAP_PACKAGES:+$'\n'}$PACKAGE_NAME"
                ;;
        esac

        case "$PACKAGE_NAME" in
            pacemaker|pacemaker-*|pcs|pcs-*|corosync|corosync-*|fence-agents|fence-agents-*)
                HA_PACKAGES+="${HA_PACKAGES:+$'\n'}$PACKAGE_NAME"
                ;;
        esac
    done <<< "$INSTALLED_PACKAGE_NAMES"

    RECOMMENDED_IMAGE_SUFFIX=""
    RECOMMENDED_IMAGE_TYPE=""

    if [[ -n "$SAP_PACKAGES" && -n "$HA_PACKAGES" ]]; then
        RECOMMENDED_IMAGE_SUFFIX="sap-ha"
        RECOMMENDED_IMAGE_TYPE="SAP HA"
    elif [[ -n "$SAP_PACKAGES" ]]; then
        RECOMMENDED_IMAGE_SUFFIX="sapapps"
        RECOMMENDED_IMAGE_TYPE="SAP Apps"
    elif [[ -n "$HA_PACKAGES" ]]; then
        RECOMMENDED_IMAGE_SUFFIX="ha"
        RECOMMENDED_IMAGE_TYPE="HA"
    fi

    while [[ -n "$RECOMMENDED_IMAGE_SUFFIX" && "$IMAGE_SUFFIX" != "$RECOMMENDED_IMAGE_SUFFIX" ]]; do
        echo        
        warn "The selected image type does not match the installed workload packages."
        warn "Selected image type    : $IMAGE_SUFFIX"
        warn "Recommended image type : $RECOMMENDED_IMAGE_TYPE"

        if [[ -n "$SAP_PACKAGES" ]]; then
            echo
            echo "Detected SAP-related packages:"
            echo "$SAP_PACKAGES"
        fi

        if [[ -n "$HA_PACKAGES" ]]; then
            echo
            echo "Detected HA-related packages:"
            echo "$HA_PACKAGES"
        fi

        echo
        warn "Selecting an incompatible image type may install incorrect RHUI repositories."        
        echo

        read -rp "Re-select the image type? [Y/c to continue anyway]: " VALIDATION_CHOICE

        case "$VALIDATION_CHOICE" in
            ""|[Yy])
                select_custom_image_type
                ;;
            [Cc])
                warn "Continuing with explicitly selected image type: $IMAGE_SUFFIX"
                break
                ;;
            *)
                warn "Enter Y to re-select or C to continue with the current selection."
                ;;
        esac
    done

    if [[ -z "$RECOMMENDED_IMAGE_SUFFIX" ]]; then
        info "No installed SAP or HA workload packages were detected."
    elif [[ "$IMAGE_SUFFIX" == "$RECOMMENDED_IMAGE_SUFFIX" ]]; then
        ok "Selected image type matches the installed workload packages"
    fi
else
    OFFER_LOWER=$(echo "$OFFER" | tr '[:upper:]' '[:lower:]')
    IMAGE_SUFFIX="standard"

    if echo "$OFFER_LOWER" | grep -q "sapapps"; then
        IMAGE_SUFFIX="sapapps"
    elif echo "$OFFER_LOWER" | grep -q "sap" && echo "$OFFER_LOWER" | grep -q "ha"; then
        IMAGE_SUFFIX="sap-ha"
    elif echo "$OFFER_LOWER" | grep -q "sap"; then
        IMAGE_SUFFIX="sap"
    elif echo "$OFFER_LOWER" | grep -q "ha"; then
        IMAGE_SUFFIX="ha"
    fi

    ok "Detected Image Type : $IMAGE_SUFFIX"
fi

#--------------------------------------------------
# Unsupported SAP / HA Minor Version Validation
#--------------------------------------------------

if [[ "$IMAGE_SUFFIX" == "sapapps" || \
      "$IMAGE_SUFFIX" == "sap-ha" || \
      "$IMAGE_SUFFIX" == "ha" ]]; then
    section "Validating Supported Minor Version"
    SUPPORTED_VERSION=0

    # Last supported releases
    if [[ "$LAST_MINOR_RELEASE" -eq 1 ]]; then
        SUPPORTED_VERSION=1

    # Supported EUS/E4S releases = even minor versions
    elif (( OS_MINOR % 2 == 0 )); then
        SUPPORTED_VERSION=1
    fi

    if [[ "$SUPPORTED_VERSION" -ne 1 ]]; then

        echo
        fail "Detected unsupported OS minor version: $OS_VERSION.$OS_MINOR

This VM appears to have been updated using incorrect repositories/packages.

Supported versions for $IMAGE_SUFFIX images include:
  - Even-numbered EUS/E4S minor releases
  - Last supported x.10 releases

Examples:
  - 8.2
  - 8.4
  - 8.6
  - 8.8
  - 8.10
  - 9.2
  - 9.4
  - 9.6
  - 9.8
  - 9.10

Current detected version:
  - $OS_VERSION.$OS_MINOR

Recommended action:
  Create a support case with Microsoft to validate and correct RHUI/repository configuration."
    fi

    ok "Supported OS minor version detected"

fi

#--------------------------------------------------
# 5. RHUI Support Model Detection
#--------------------------------------------------
section "RHUI Support Model Detection"

#--------------------------------------------------
# Check EUS availability for STANDARD images
#--------------------------------------------------
EUS_AVAILABLE=0

if [[ "$IMAGE_SUFFIX" == "standard" ]]; then

    EUS_REPO="microsoft-azure-rhel${OS_VERSION}-eus"
    PREVIEW_CONFIG="/tmp/rhui-preview.repo"

    cat <<EOF > "$PREVIEW_CONFIG"
[$EUS_REPO]
name=EUS Repo
baseurl=https://${RHUI_HOST}/pulp/repos/unprotected/${EUS_REPO}
enabled=1
gpgcheck=0
sslverify=1
EOF

    EUS_PKGS=$(repo_query "$PREVIEW_CONFIG" "%{name}" "rhui-azure-rhel${OS_VERSION}-eus*" | sort -u)

    if [[ -n "$EUS_PKGS" ]]; then
        EUS_AVAILABLE=1
    fi

    rm -f "$PREVIEW_CONFIG"

fi

#--------------------------------------------------
# 6. Automatic EUS / Non-EUS Decision
#--------------------------------------------------

if [[ "$IMAGE_SUFFIX" != "standard" ]]; then

    if [[ "$LAST_MINOR_RELEASE" -eq 1 ]]; then
        warn "EUS is not applicable for this system"
        echo ""
        info "Proceeding with BASE RHUI package automatically"
    else
        warn "Non-EUS is not applicable for this system"
        echo ""
        info "Proceeding with EUS RHUI package automatically"
    fi

else

    # Last supported minor versions should always use Non-EUS
    if [[ "$LAST_MINOR_RELEASE" -eq 1 ]]; then

        info "Detected last supported minor version ($OS_VERSION.$OS_MINOR)"
        info "Proceeding with Non-EUS RHUI package automatically"
        MODE="2"

    # Even minor version -> EUS
    # Odd minor version  -> Non-EUS
    elif (( OS_MINOR % 2 == 0 )); then

        if [[ "$EUS_AVAILABLE" -eq 1 ]]; then
            info "Detected OS version ($OS_VERSION.$OS_MINOR)"
            info "Proceeding with EUS RHUI package automatically"
            MODE="1"
        else
            warn "Even minor version detected but EUS repo not available"
            info "Proceeding with Non-EUS automatically"
            MODE="2"
        fi

    else

        info "Detected ODD minor version ($OS_MINOR)"
        info "Proceeding with Non-EUS RHUI package automatically"
        MODE="2"

    fi

fi

#--------------------------------------------------
# Installation Confirmation for Custom Images
#--------------------------------------------------
if [[ "$IMAGE_CLASSIFICATION" == "Custom image" ]]; then
    section "Installation Summary"

    echo "Billing Model : $BILLING_MODEL"
    echo "Image Type    : $IMAGE_SUFFIX"
    echo "OS Version    : $OS_VERSION.$OS_MINOR"
    echo

    read -rp "Continue with RHUI installation? [y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Installation cancelled by user"
        exit 0
    fi
fi

#--------------------------------------------------
# 7. Package Selection
#--------------------------------------------------
section "Selecting RHUI Package"

PKG_BASE="rhui-azure-rhel${OS_VERSION}"

case "$IMAGE_SUFFIX" in

    sapapps)
        if [[ "$LAST_MINOR_RELEASE" -eq 1 ]]; then
            PKG="${PKG_BASE}-base-sap-apps"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-base-sap-apps"
        else
            PKG="${PKG_BASE}-sapapps"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-sapapps"
        fi
        ;;

    sap-ha)
        if [[ "$LAST_MINOR_RELEASE" -eq 1 ]]; then
            PKG="${PKG_BASE}-base-sap-ha"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-base-sap-ha"
        else
            PKG="${PKG_BASE}-sap-ha"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-sap-ha"
        fi
        ;;

    ha)
        if [[ "$LAST_MINOR_RELEASE" -eq 1 ]]; then
            PKG="${PKG_BASE}-base-ha"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-base-ha"
        else
            PKG="${PKG_BASE}-ha"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-ha"
        fi
        ;;

    sap)
        PKG="${PKG_BASE}-sap"
        REPO_NAME="microsoft-azure-rhel${OS_VERSION}-sap"
        ;;

    standard)
        if [[ "$MODE" == "1" ]]; then
            PKG="${PKG_BASE}-eus"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}-eus"
        else
            PKG="${PKG_BASE}"
            REPO_NAME="microsoft-azure-rhel${OS_VERSION}"
        fi
        ;;

esac

ok "Selected Package : $PKG"
ok "Repo Name        : $REPO_NAME"

#--------------------------------------------------
# 8. Create Repo
#--------------------------------------------------
CONFIG_FILE="/tmp/rhui.repo"

section "Creating Repository Configuration"

cat <<EOF > "$CONFIG_FILE"
[$REPO_NAME]
name=Microsoft Azure RPMs for RHEL $OS_VERSION ($REPO_NAME)
baseurl=https://${RHUI_HOST}/pulp/repos/unprotected/${REPO_NAME}
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
sslverify=1
EOF

ok "Repository file created"

#--------------------------------------------------
# 9. Install RHUI
#--------------------------------------------------
section "Installing RHUI Package"

PM=$(pkg_mgr)
TMP_LOG="/tmp/rhui_install.log"

info "Installing package: $PKG"

if ! $PM --config "$CONFIG_FILE" install -y "$PKG" >"$TMP_LOG" 2>&1; then
    echo
    echo "✖ Installation failed"
    echo
    echo "------ ERROR DETAILS ------"
    cat "$TMP_LOG"
    echo "---------------------------"
    show_rhui_failure_guidance
    exit 1
fi

ok "Installed: $PKG"

#--------------------------------------------------
# 10. VERSION LOCK
#--------------------------------------------------
section "Configuring release version lock"

CURRENT_VERSION="$VERSION_ID"
SET_LOCK=0

# SAP / HA → only if NOT base versions
if [[ "$IMAGE_SUFFIX" != "standard" ]]; then
    if [[ "$LAST_MINOR_RELEASE" -ne 1 ]]; then
        SET_LOCK=1
    fi
fi

# Standard → only if EUS selected
if [[ "$IMAGE_SUFFIX" == "standard" && "${MODE:-}" == "1" ]]; then
    SET_LOCK=1
fi

if [[ "$SET_LOCK" -eq 1 ]]; then

    if [[ "$OS_VERSION" -ge 8 ]]; then
        VAR_PATH="/etc/dnf/vars/releasever"
    else
        VAR_PATH="/etc/yum/vars/releasever"
    fi

    mkdir -p "$(dirname "$VAR_PATH")"
    echo "$CURRENT_VERSION" > "$VAR_PATH"

    ok "releasever locked to $CURRENT_VERSION"

else
    info "releasever lock not required"
fi

#--------------------------------------------------
# 11. Validation
#--------------------------------------------------
section "Validating Installation"

rpm -qa | grep -i rhui || fail "RHUI install failed"

ok "RHUI package verified"

$PM repolist >/dev/null 2>&1 || fail "Repo access failed"

ok "Repositories accessible"

#--------------------------------------------------
# 12. Summary
#--------------------------------------------------
section "Installation Complete"

echo "RHUI installation completed successfully!"
echo
echo "Summary"

line

echo "OS                   : $PRETTY_NAME"
echo "OS created from      : $OS_CREATED_FROM"
echo "Image classification : $IMAGE_CLASSIFICATION"
echo "Billing model        : $BILLING_MODEL"
echo "Image type           : $IMAGE_SUFFIX"
echo "Repo                 : $REPO_NAME"
echo "Package              : $(rpm -qa | grep -i rhui)"

line
