# RHUI Installation Automation for Azure RHEL VMs

> [!IMPORTANT]
> This script is intended for **RHUI installation only**.
>
> The script first checks whether an RHUI package is already installed on the virtual machine:
>
> - If RHUI is not installed, the script continues with RHUI package selection and installation.
> - If RHUI is already installed, the script displays the detected RHUI package information and exits safely.
> - The script does not upgrade, replace, repair, migrate, reinstall, or modify an existing RHUI installation.

> [!NOTE]
> RHUI validation currently applies only to RHUI packages installed by the script during the current execution.
>
> If an RHUI package is already present when the script starts, the script exits without validating the health or configuration of the existing RHUI installation.
>
> Validation and health assessment of pre-existing RHUI installations are planned as future enhancements.

## Overview

The `rhui-install.sh` script automates the installation and post-installation validation of Red Hat Update Infrastructure (RHUI) packages on Azure Red Hat Enterprise Linux (RHEL) virtual machines.

The script reduces the complexity of identifying the appropriate RHUI package and repository configuration by considering:

- RHEL major and minor versions
- Azure billing model
- Azure Marketplace or custom-image origin
- Azure image workload type
- EUS or non-EUS eligibility
- SAP Applications workloads
- SAP High Availability workloads
- RHEL High Availability workloads
- Last-supported minor releases

The script validates the operating-system version, determines or collects the image type, selects the appropriate RHUI package, creates temporary repository configuration, installs the package, configures release-version locking when required, and performs post-installation validation.

## Features

### Operating-System Detection

The script reads `/etc/os-release` and detects:

- Installed RHEL version
- RHEL major version
- RHEL minor version
- Last-supported minor releases

Examples include:

- RHEL 7.x
- RHEL 8.x
- RHEL 9.x

The detected version is used to determine the correct package manager, RHUI package, repository, support model, and release-version-locking requirements.

### Existing RHUI Detection

Before making any changes, the script checks whether RHUI packages are already installed.

If one or more RHUI packages are detected, the script:

1. Displays a warning that RHUI is already installed.
2. Displays the detected RHUI package information.
3. Exits without making changes.

The script does not currently validate whether a pre-existing RHUI installation is healthy, correctly configured, or appropriate for the VM image type.

### Billing Model Validation

The script supports the following Azure billing models:

- **PAYG:** Pay-As-You-Go
- **BYOS:** Bring Your Own Subscription

#### PAYG

Azure RHUI is intended for eligible RHEL PAYG virtual machines. If PAYG is selected, the script continues with image detection, RHUI package selection, and installation.

#### BYOS

If BYOS is selected, the script:

- Explains that Azure RHUI is not intended for BYOS systems.
- Advises the administrator to use Red Hat Subscription Manager or a Red Hat Satellite server.
- Exits without installing or modifying RHUI packages.

## Image Detection and RHUI Package Selection

The tool handles Azure Marketplace images and custom images differently.

### Azure Marketplace Images

For an Azure Marketplace image, the tool retrieves image information from the Azure Instance Metadata Service.

When sufficient Marketplace image information is available, the tool uses the metadata to identify the applicable image or workload type and determine the appropriate RHUI package.

Depending on the detected image, the package-selection logic can account for:

- Standard RHEL
- RHEL for SAP Applications
- RHEL for SAP High Availability
- RHEL High Availability
- EUS or non-EUS configuration
- Last-supported minor-release package variants

The automatically selected RHUI package is displayed before installation.

### Custom Images

For a custom image, captured image, migrated image, or image without sufficient Marketplace metadata, the original image characteristics might not be reliably identifiable from Azure metadata.

In this situation, the tool requests user input for the intended image type.

The available image types are:

| Image type | Description |
|---|---|
| Standard | Standard RHEL workload |
| SAP Apps | RHEL for SAP Applications workload |
| SAP HA | RHEL for SAP High Availability workload |
| HA | RHEL High Availability workload |

For a custom image, the tool:

1. Requests the intended image type from the user.
2. Verifies relevant installed package information.
3. Evaluates the RHEL major and minor versions.
4. Determines the proposed RHUI package and repository.
5. Displays the detected and selected configuration.
6. Requests explicit user confirmation before installation.

This additional confirmation helps reduce the risk of installing an RHUI package that does not match the custom image’s intended workload.

## Automatic RHUI Package Selection

After the image or workload type is determined, the script selects the appropriate RHUI package.

Package-selection logic includes:

- Base RHUI packages
- Standard RHUI packages
- EUS RHUI packages
- SAP Applications-specific RHUI packages
- SAP High Availability-specific RHUI packages
- High Availability-specific RHUI packages
- Last-supported-release RHUI package variants

The selected package and repository are displayed before installation.

The user must confirm the installation before the script proceeds.

## EUS and Non-EUS Detection

For Standard images, the script determines whether EUS or non-EUS RHUI should be used.

The decision logic considers:

- RHEL major version
- RHEL minor version
- Even-numbered EUS minor releases
- Availability of the corresponding EUS repository
- Odd-numbered minor releases
- Last-supported minor releases

For SAP and High Availability workloads, the script evaluates whether the detected RHEL minor release is valid for the applicable EUS or E4S support model.

## Supported-Version Validation

For SAP Applications, SAP High Availability, and High Availability workloads, the script validates that the VM is running an appropriate RHEL minor version.

Supported release patterns generally include:

- Even-numbered EUS or E4S minor releases
- The final supported minor release for the applicable RHEL major version

Examples include:

- RHEL 8.2
- RHEL 8.4
- RHEL 8.6
- RHEL 8.8
- RHEL 8.10
- RHEL 9.2
- RHEL 9.4
- RHEL 9.6
- RHEL 9.8
- RHEL 9.10

If an unsupported minor version is detected for an SAP or HA workload, the script stops before installation and displays guidance.

The administrator should then:

- Verify the current operating-system version.
- Review the VM’s image and repository history.
- Confirm whether the VM was updated using repositories intended for another image type.
- Open a Microsoft support case if configuration validation or correction is required.

## Repository Configuration

The script creates a temporary repository configuration pointing to the applicable Azure RHUI repository.

The temporary configuration includes:

- Azure RHUI repository name
- Azure RHUI repository URL
- Microsoft GPG key
- GPG signature validation
- SSL verification

The temporary repository configuration is used to install the selected RHUI package.

## Installation Confirmation

Before installing the RHUI package, the script displays an installation summary.

The summary includes relevant information such as:

- Billing model
- Image type
- Operating-system version
- Selected RHUI package
- Selected RHUI repository

The administrator must explicitly confirm the installation.

If confirmation is not provided, the script exits without installing RHUI.

## RHUI Package Installation

The script uses the package manager appropriate for the detected RHEL version:

- `yum` for applicable older RHEL releases
- `dnf` for applicable newer RHEL releases

Installation output is written to a temporary log.

If installation fails, the script:

- Stops execution.
- Displays an installation failure message.
- Prints the captured package-manager error details.
- Does not report the installation as successful.

## Release-Version Locking

The script configures `releasever` locking when required.

Release-version locking can apply to:

- Standard EUS installations
- SAP EUS or E4S workloads
- SAP High Availability workloads
- High Availability workloads

The lock helps prevent unintended movement to a RHEL minor version that is not appropriate for the configured RHUI repository or workload support model.

Depending on the RHEL major version, the release version is written under the appropriate `yum` or `dnf` variable path.

Release-version locking is not configured when it is not required, such as for applicable base or last-supported-release package selections.

## Post-Installation Validation

Post-installation validation is performed only when the script installs RHUI during the current execution.

The script verifies:

- An RHUI package is installed.
- The installed RHUI package can be identified through RPM.
- The package manager can access the configured repositories.
- The installation completed without a package-manager failure.

After successful validation, the script displays an installation summary containing information such as:

- Billing model
- Operating-system information
- Image type
- Repository name
- Installed RHUI package

### Current Validation Limitation

If RHUI is already installed before the script starts, the script exits without validating:

- Whether the existing RHUI package matches the image type
- Whether the existing repositories are correct
- Whether RHUI certificates are valid
- Whether repository connectivity is functional
- Whether release-version locking is correctly configured
- Whether the existing RHUI installation requires repair or replacement

Health validation of pre-existing RHUI installations is planned as a future enhancement.

## Prerequisites

### Supported Operating Systems

The tool is intended for supported Azure RHEL virtual machines, including applicable releases of:

- Red Hat Enterprise Linux 7.x
- Red Hat Enterprise Linux 8.x
- Red Hat Enterprise Linux 9.x

Actual RHUI package and repository availability depends on the RHEL version, image type, billing model, and supported Azure RHUI release stream.

### Required Permissions

Run the script as `root` or by using `sudo`.

The executing account must be able to:

- Query installed RPM packages
- Read operating-system information
- Create temporary repository files
- Install RPM packages
- Write release-version variables when required
- Query package repositories

### Network Requirements

The VM must have:

- DNS resolution
- HTTPS connectivity to Azure RHUI endpoints
- HTTPS connectivity to Microsoft package-signing-key endpoints
- Network security rules that permit the required outbound traffic

Proxy, firewall, route-table, or Network Security Group restrictions can prevent repository access.

### Azure Metadata Access

Marketplace-image detection requires access to the Azure Instance Metadata Service from within the virtual machine.

If usable Marketplace metadata is unavailable, the tool follows the custom-image workflow and requests the image type from the user.

## Usage

### Download the Script

Download the script from the Azure Support Scripts repository:
```bash
wget -O rhui-install.sh https://raw.githubusercontent.com/Trivikram-Paduchuru/azure-support-scripts/refs/heads/master/Linux_scripts/RHUI-Install/rhui-install.sh
```
### Make the Script Executable

    chmod +x rhui-install.sh

### Run the Script

    sudo ./rhui-install.sh
