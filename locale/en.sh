#!/usr/bin/env bash
# English locale for immutable-live installer

declare -gA MSG=(
    # Main titles
    [APP_TITLE]="immutable-live Installation"
    [DIALOG_DRIVE_TITLE]="Select Target Drive"
    [DIALOG_DRIVE_DESC]="Select the target USB drive for immutable-live installation:\n(Warning: All data on the selected drive will be erased!)"
    [DIALOG_PERSIST_TITLE]="Persistence Size"
    [DIALOG_PERSIST_DESC]="Selected drive: {DRIVE} ({MODEL}, {SIZE})\n\nEnter the size of the Persistence partition:\n- Percentage: 50%, 75%\n- Megabytes/Gigabytes: 4096M, 8G, 16GiB"
    [DIALOG_LUKS_TITLE]="LUKS Encryption"
    [DIALOG_LUKS_DESC]="Enter password for Persistence partition encryption (LUKS):\n(Leave empty for no encryption)"
    [DIALOG_LUKS_CONFIRM_TITLE]="Confirm LUKS Password"
    [DIALOG_LUKS_CONFIRM_DESC]="Re-enter LUKS password to confirm:"
    [DIALOG_HOSTNAME_TITLE]="Hostname"
    [DIALOG_HOSTNAME_DESC]="Enter hostname (Latin letters, numbers and hyphen):"
    [DIALOG_USER_TITLE]="User Account"
    [DIALOG_USER_DESC]="Enter Linux username:"
    [DIALOG_USERPASS_TITLE]="User Password"
    [DIALOG_USERPASS_DESC]="Enter password for user {USER}:"
    [DIALOG_USERPASS_CONFIRM_TITLE]="Confirm Password"
    [DIALOG_USERPASS_CONFIRM_DESC]="Re-enter user password:"
    [DIALOG_AUTOLOGIN_TITLE]="Automatic Login"
    [DIALOG_AUTOLOGIN_DESC]="Enable automatic login for user {USER}?"
    [DIALOG_SWAP_TITLE]="Swap Configuration"
    [DIALOG_SWAP_DESC]="Enable swap file on Live USB?"
    [DIALOG_SWAP_SIZE_TITLE]="Swap Size"
    [DIALOG_SWAP_SIZE_DESC]="Enter swap size (e.g., 2G, 2048M or 10%):\nTotal drive capacity: {SIZE}"
    [DIALOG_WARNING_ROOT_TITLE]="WARNING: Dangerous Mode"
    [DIALOG_WARNING_ROOT_DESC]="You are about to display ALL drives, including the system drive with your current OS.\n\nRandom selection of the system drive will COMPLETELY DESTROY your operating system!\n\nDisplay all drives?"
    [DIALOG_CRITICAL_TITLE]="CRITICAL WARNING"
    [DIALOG_CRITICAL_DESC]="WARNING! You selected the SYSTEM DRIVE ({DRIVE}) which contains the current OS (/ root).\n\nInstalling on this drive will COMPLETELY DESTROY your operating system!\n\nAre you ABSOLUTELY sure you want to continue?"
    [DIALOG_FINAL_TITLE]="Final Confirmation"
    [DIALOG_SUMMARY]="Installation parameters:
- Drive:            {DRIVE} ({MODEL}, {SIZE})
- Persistence:      {PERSIST_MiB} MiB ({PERSIST_INPUT})
- LUKS Encryption:  {LUKS_STATUS}
- Hostname:         {HOSTNAME}
- User:             {USER}
- Auto-login:       {AUTOLOGIN}
- Swap:             {SWAP_STATUS}

WARNING: All existing partitions and data on {DRIVE} will be COMPLETELY DESTROYED!
Continue with installation?"
    [DIALOG_SUCCESS_TITLE]="Success"
    [DIALOG_SUCCESS_DESC]="immutable-live has been successfully installed to {DRIVE}!\n\nCopy your Live ISO images to the /iso directory on the USB drive."

    # Error messages
    [ERR_COMMAND_FAILED]="Command failed at line {LINE} (code {STATUS}): {CMD}. Installation stopped; the drive may require cleanup/repartitioning."
    [ERR_ROOT_REQUIRED]="Error: Root privileges required. Run with sudo."
    [ERR_DIALOG_NOT_FOUND]="Error: Neither whiptail nor dialog is installed."
    [ERR_DIALOG_CANCELLED]="Installer cancelled or dialog failed: {CONTEXT}."
    [ERR_NO_DRIVES]="No disk drives found."
    [ERR_NO_USB]="No USB drives detected. Show all drives including the system drive? Selecting it may destroy your current OS."
    [ERR_PERSIST_TOO_SMALL]="Persistence size must be at least 512 MiB."
    [ERR_PERSIST_TOO_LARGE]="Persistence size is too large. Leave at least 512 MiB for Ventoy boot partition and ISO images."
    [ERR_LUKS_MISMATCH]="LUKS passwords do not match. Try again."
    [ERR_HOSTNAME_INVALID]="Invalid hostname. Use letters, numbers, dot or hyphen."
    [ERR_USER_INVALID]="Invalid username. Use lowercase Latin letters, numbers, '_' and '-'."
    [ERR_USERPASS_EMPTY]="Password cannot be empty."
    [ERR_USERPASS_MISMATCH]="Passwords do not match. Try again."
    [ERR_SWAP_INVALID]="Error: Swap size must be positive and smaller than Persistence partition ({MAX} MiB)."
    [ERR_ENV_EXAMPLE_NOT_FOUND]=".env.example file not found: {PATH}"
    [ERR_VENTOY_FAILED]="Ventoy did not create expected partitions 1 and 2. Check Ventoy output and retry."
    [ERR_PERSISTENCE_PARTITION]="Failed to create or detect Persistence partition ({PART})."
    [ERR_VENTOY_PARTITION]="Failed to mount Ventoy partition ({PART}). ExFAT support may not be installed."
    [ERR_COMMAND_MISSING]="Required command not found: {CMD}"
    [ERR_PARTITION_TOOL_MISSING]="parted, sfdisk or fdisk is required to create persistence partition."
    [ERR_LUKS_TOOL_MISSING]="cryptsetup is required for LUKS encryption."

    # Info/Warning messages
    [INFO_DOWNLOADING_VENTOY]="Ventoy binaries not found in tools/ventoy. Downloading Ventoy..."
    [INFO_STARTING]="Starting preparation of drive {DRIVE}..."
    [INFO_UNMOUNTING]="Unmounting existing partitions on {DRIVE}..."
    [INFO_INSTALLING_VENTOY]="Installing Ventoy (reserving {SIZE} MiB at end of drive)..."
    [INFO_LARGE_DISK_GPT]="Drive larger than 2 TiB: enabling GPT for Ventoy."
    [INFO_CREATING_PERSISTENCE]="Creating Persistence partition..."
    [INFO_FORMATTING]="Formatting ext4 filesystem (label=persistence) on {DEV}..."
    [INFO_LUKS_SETUP]="Setting up LUKS1 encryption on {PART}..."
    [INFO_DEPLOYING]="Deploying persistence configuration files..."
    [INFO_ENV_CREATED]="Created .env from .env.example with 600 permissions"
    [INFO_CONFIGURING_VENTOY]="Configuring Ventoy bootloader on partition {PART}..."
    [INFO_COMPLETE]="Installation completed successfully!"

    # Drive selection
    [DRIVE_TAG_SYSTEM]="[SYSTEM (ROOT)]"
    [DRIVE_TAG_INTERNAL]="[Internal Disk]"
    [DRIVE_TAG_USB]="[USB/Removable]"
    [DRIVE_OPTION_SHOW_ALL]="[!] Show all drives (including system)"

    # Labels
    [LABEL_ENABLED]="Enabled (LUKS1)"
    [LABEL_DISABLED]="Disabled"
    [LABEL_ENABLED_SWAP]="Enabled ({SIZE})"
    [LABEL_DISABLED_SWAP]="Disabled"
    [LABEL_ENABLED_AUTOLOGIN]="Enabled"
    [LABEL_DISABLED_AUTOLOGIN]="Disabled"
)