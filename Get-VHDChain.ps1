 function Get-VHDChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$StartVHD
    )

    $chain = @()

    try {
        $currentVHD = Get-VHD -Path $StartVHD -ErrorAction Stop
    }
    catch {
        Write-Error "Could not get VHD info for $StartVHD. $_"
        return $null
    }

    $chain = ,$currentVHD

    while ($currentVHD.ParentPath) {
        try {
            $parentPath = $currentVHD.ParentPath
            if (-not (Test-Path $parentPath)) {
                Write-Warning "Parent VHD file not found: $parentPath"
                break
            }

            $parentVHD = Get-VHD -Path $parentPath -ErrorAction Stop
            $chain = ,$parentVHD + $chain
            $currentVHD = $parentVHD
        }
        catch {
            Write-Error "Error retrieving parent VHD info from $($currentVHD.ParentPath). $_"
            break
        }
    }

    return $chain
} 
