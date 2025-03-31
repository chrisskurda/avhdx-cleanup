 param(
    [string]$VMName,
    [ValidateSet("delete", "merge", "both", "prompt")]
    [string]$Action = "prompt",
    [switch]$AutoConfirm,
    [string]$ConfigPath
)

function Get-VHDChain {
    param([string]$StartVHD)
    $chain = @()
    try {
        $currentVHD = Get-VHD -Path $StartVHD -ErrorAction Stop
    } catch {
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
        } catch {
            Write-Error "Error retrieving parent VHD info from $($currentVHD.ParentPath). $_"
            break
        }
    }
    return $chain
}

# --- Load config file if present ---
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        if (-not $VMName)      { $VMName = $config.VMName }
        if ($Action -eq 'prompt' -and $config.Action) { $Action = $config.Action }
        if (-not $AutoConfirm -and $config.AutoConfirm) { $AutoConfirm = $true }
        if ($config.SearchPathOverride) { $SearchPathOverride = $config.SearchPathOverride }
    } catch {
        Write-Warning "⚠ Failed to parse config file: $ConfigPath"
    }
}

# --- Prompt if still missing ---
if (-not $VMName) {
    $VMName = Read-Host "Enter the name of the VM"
}

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "❌ VM '$VMName' not found." -ForegroundColor Red
    exit 1
}

# Get the live disk
$disk = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
if (-not $disk) {
    Write-Host "❌ No disk found for VM '$VMName'." -ForegroundColor Red
    exit 1
}
$startPath = $disk.Path
$activeChain = Get-VHDChain -StartVHD $startPath
if (-not $activeChain) {
    Write-Host "❌ Failed to retrieve active VHD chain." -ForegroundColor Red
    exit 1
}
$activePaths = $activeChain | Select-Object -ExpandProperty Path

# Search for orphans
$searchPath = if ($SearchPathOverride) { $SearchPathOverride } else { Split-Path $startPath }
$allAVHDX = Get-ChildItem -Path $searchPath -Filter *.avhdx -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
$orphans = $allAVHDX | Where-Object { $_ -notin $activePaths }

# Output status
Write-Host "`n🟢 Active Chain for '$VMName':" -ForegroundColor Green
$activePaths | ForEach-Object { Write-Host " → $_" }

if ($orphans.Count -gt 0) {
    Write-Host "`n🟡 Orphaned .avhdx files found:" -ForegroundColor Yellow
    $orphans | ForEach-Object { Write-Host " ⚠ $_" }
} else {
    Write-Host "`n✅ No orphaned .avhdx files found." -ForegroundColor Green
}

# --- Prompt for action if set to 'prompt' ---
if ($Action -eq "prompt") {
    Write-Host "`nWhat do you want to do?"
    Write-Host "1 = Delete orphans"
    Write-Host "2 = Merge active chain"
    Write-Host "3 = Do both"
    Write-Host "4 = Exit"
    $input = Read-Host "Enter your choice (1-4)"
    switch ($input) {
        '1' { $Action = "delete" }
        '2' { $Action = "merge" }
        '3' { $Action = "both" }
        default { Write-Host "❌ No action taken. Exiting."; exit }
    }
}

# --- Perform deletion ---
if ($Action -in @("delete", "both")) {
    if ($orphans.Count -gt 0) {
        if (-not $AutoConfirm) {
            $confirm = Read-Host "Are you sure you want to delete all orphaned .avhdx files? (Y/N)"
            if ($confirm -ne "Y") { Write-Host "❌ Skipping deletion."; $skipDelete = $true }
        }
        if (-not $skipDelete) {
            $orphans | ForEach-Object {
                try {
                    Remove-Item -Path $_ -Force
                    Write-Host "✔ Deleted: $_"
                } catch {
                    Write-Warning "❌ Failed to delete $_"
                }
            }
        }
    } else {
        Write-Host "⚠ No orphaned files to delete."
    }
}

# --- Perform merge ---
if ($Action -in @("merge", "both")) {
    if ($vm.State -ne 'Off') {
        Write-Host "⚠ VM must be powered off to merge disks. Current state: $($vm.State)" -ForegroundColor Red
        exit 1
    }

    for ($i = $activePaths.Count - 1; $i -gt 0; $i--) {
        $child = $activePaths[$i]
        $parent = $activePaths[$i - 1]
        Write-Host "Merging $child → $parent"
        try {
            Merge-VHD -Path $child -DestinationPath $parent -Force
            Write-Host "✔ Merged $child into $parent"
        } catch {
            Write-Warning "❌ Failed to merge ${child}: $_"
        }
    }
    Write-Host "`n✅ Merge complete."
} 
