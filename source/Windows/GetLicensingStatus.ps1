<#
    .SYNOPSIS
        Retrieve a list of active machines in the environment and check license status
    .NOTES
        Author: Jesse Reichman (Noveris)
#>

[CmdletBinding(DefaultParameterSetName="retrieve")]
param(
    [Parameter(ParameterSetName="retrieve", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchBase,

    [Parameter(ParameterSetName="retrieve", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$Filter,

    [Parameter(ParameterSetName="retrieve", Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$LDAPFilter,

    [Parameter(ParameterSetName="provided", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Systems,

    [Parameter(ParameterSetName="retrieve", Mandatory=$false)]
    [ValidateNotNull()]
    [int]$MachineAge = 30,

    [Parameter(Mandatory=$false)]
    [ValidateNotNull()]
    [switch]$AsCSV = $false
)

########
# Global settings
Set-StrictMode -Version 2
$InformationPreference = "Continue"
$ErrorActionPreference = "Stop"

<#
#>
Function Get-RemoteClassInstance
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClassName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName
    )

    process
    {
        #Attempt via CIM first
        try {
            Get-CimInstance -Property * -ComputerName $ComputerName -ClassName $ClassName
            return
        } catch {
            Write-Warning "Failed to retrieve information via CIM: $_"
        }

        # Fallback to WMI
        try {
            Get-WmiObject -Property * -ComputerName $ComputerName -Class $ClassName
            return
        } catch {
            Write-Warning "Failed to retrieve information via WMI: $_"
        }

        # Nothing worked, write-error
        Write-Error "No remaining methods to retrieve class information from system"
    }
}

########
# If required, retrieve a list of the systems using supplied parameters
if ($PSCmdlet.ParameterSetName -eq "retrieve")
{
    # Add relevant parameters that have been supplied
    $retrieve = @{
        Properties = "lastLogonDate"
    }
    "LDAPFilter", "Filter", "SearchBase" | ForEach-Object {
        if ($PSBoundParameters.Keys -contains $_)
        {
            $retrieve[$_] = $PSBoundParameters[$_]
        }
    }

    # Retrieve the list of systems
    try {
        $Systems = Get-ADComputer @retrieve |
            Where-Object { $_.lastLogonDate -gt [DateTime]::Now.AddDays(-[Math]::Abs($MachineAge)) } |
            ForEach-Object { $_.Name }
    } catch {
        Write-Information "Failed to retrieve a list of systems from active directory: $_"
        throw $_
    }
}

########
# Iterate through each system to get license details
$results = $Systems | ForEach-Object {
    $name = $_

    Write-Verbose "Operating on $name"
    $state = [PSCustomObject]@{
        System = $name
        Type = "Unknown"
        Version = "Unknown"
        LicenseProduct = "Unknown"
        LicenseStatus = -1
        LicenseReason = -1
        LicenseDescription = ""
        ProductKeyChannel = ""
        KMSServer = ""
    }

    # Retrieve licensing information
    try {
        Write-Verbose "Retrieving licensing information"

        # Get licensing information
        $license = Get-RemoteClassInstance -ClassName SoftwareLicensingProduct -ComputerName $name |
            Where-Object { $_.LicenseStatus -gt 0 } |
            Sort-Object -Property LicenseStatus |
            Select-Object -First 1
        $licenseStatus = $license.LicenseStatus

        # Translations for license codes can be found here: https://docs.microsoft.com/en-us/previous-versions/windows/desktop/sppwmi/softwarelicensingproduct#properties
        switch ($licenseStatus)
        {
            0 { $state.LicenseStatus = "0 (Unlicensed)" }
            1 { $state.LicenseStatus = "1 (Licensed)" }
            2 { $state.LicenseStatus = "2 (OOBGrace)" }
            3 { $state.LicenseStatus = "3 (OOTGrace)" }
            4 { $state.LicenseStatus = "4 (NonGenuineGrace)" }
            5 { $state.LicenseStatus = "5 (Notification)" }
            6 { $state.LicenseStatus = "6 (ExtendedGrace)" }
            default { $state.LicenseStatus = "$licenseStatus (unknown)" }
        }

        if (($license | Get-Member).Name -contains "Name")
        {
            $state.LicenseProduct = $license.Name
        }

        if (($license | Get-Member).Name -contains "LicenseStatusReason")
        {
            $state.LicenseReason = $license.LicenseStatusReason
        }

        if (($license | Get-Member).Name -contains "ProductKeyChannel")
        {
            $state.ProductKeyChannel = $license.ProductKeyChannel
        }

        if (($license | Get-Member).Name -contains "DiscoveredKeyManagementServiceMachineName")
        {
            $state.KMSServer = $license.DiscoveredKeyManagementServiceMachineName
        }

        if (($license | Get-Member).Name -contains "Description")
        {
            $state.LicenseDescription = $license.Description
        }
    } catch {
        Write-Warning "Failed to retrieve licensing information from ${name}: $_"
    }

    # Retrieve system information
    try {
        Write-Verbose "Retrieving system info"

        $sysinfo = Get-RemoteClassInstance -ComputerName $name -ClassName Win32_OperatingSystem
        $state.Type = $sysinfo.Caption
        $state.Version = $sysinfo.Version
    } catch {
        Write-Warning "Failed to retrieve system information from ${name}: $_"
    }

    $state
}

########
# Display output. Format as CSV, if requested
if ($AsCSV)
{
    $results | ConvertTo-CSV -NoTypeInformation
} else {
    $results
}
