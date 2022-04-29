<#
.SYNOPSIS
    Changes the font colors in the OCCT app of PC Building Simulator.

.DESCRIPTION
    Patches PCBS's game logic DLL (Assembly-CSharp-firstpass.dll) to change  the
    font colors in the OCCT app.  Only the colors specified in the arguments are
    changed, other colors will remain unchanged.

    The colors can be reset to their original values by running the script  with
    the -Reset argument.

    By default (if no color arguments are specified), the  script  will  try  to
    read and display (-Show) the current OCCT color  settings  without  changing
    anything.

    The script always checks for compatibility by computing MD5  hashes  of  the
    relevant regions in the game logic DLL and comparing them to  known  hashes.
    There is no way to disable this check (except by editing the script).

    (tested for the Steam version of PCBS x64 v1.15.3)

    Arguments
    =========
       -PcbsDir <path> [optional]
            Specifies the installation directory of PCBS. If omitted, the script
            tries to locate  PCBS  automatically  (only  works  with  the  Steam
            version of the game).

       -Show
            Try to read and display current OCCT color settings

       -CpuTemp <color>
            Name of the color to be used for the CPU temperature row

       -CpuThrottled <color>
            Name of the color to be used for the CPU throttling row

       -GpuTemp1 <color>
            Name of the color to be used for the first GPU temperature row

       -PowerDraw1 <color> / -GpuTemp2 <color>
            Name of the color to be used for the second GPU temperature row,  or
            the power draw row in single GPU rigs.  Both settings refer  to  the
            same color in the game. If both arguments are specified, -PowerDraw1
            takes precedence over -GpuTemp2.

       -PowerDraw2 <color>
            Name of the color to be used for the power draw row in  a  dual  GPU
            rig

       -Reset
            Reverts colors back to their original values.

    Available <color> names
    =======================
        Black   (#000000)
        Blue    (#0000ff)
        Green   (#00ff00)
        Cyan    (#00ffff)
        Red     (#ff0000)
        Magenta (#ff00ff)
        Yellow  (#ffeb04)
        White   (#ffffff)
        Gray    (#7f7f7f)
        Grey    (same as Gray)

.LINK
    Patch on Github: https://github.com/cubinator/occt-colors
    PCBS: https://www.pcbuildingsim.com/pc-building-simulator
    PCBS (Steam page): https://store.steampowered.com/app/621060

.NOTES
    Patch version: 0.99
    Author:        Cubi
    Creation date: April 2022
    Game version:  PCBS x64 v1.15.3 on Steam
#>

# Note to self: Don't use .PARAMETER in the docstring as it is only shown when
# using `Get-Help occt_colors -Detailed`.

using namespace System.IO # FileStream, FileMode, FileAccess, FileShare, FileOptions, SeekOrigin
using namespace System.Security.Cryptography # MD5



[CmdletBinding(DefaultParameterSetName = 'Show Colors')]
param (
    [string]$PcbsDir,

    [Parameter(ParameterSetName='Show Colors')]
    [switch]$Show = $false,

    [Parameter(ParameterSetName='Change Colors')]
    [string]$CpuTemp,

    [Parameter(ParameterSetName='Change Colors')]
    [string]$CpuThrottled,

    [Parameter(ParameterSetName='Change Colors')]
    [string]$GpuTemp1,

    [Parameter(ParameterSetName='Change Colors')]
    [string]$GpuTemp2,

    [Parameter(ParameterSetName='Change Colors')]
    [string]$PowerDraw1,

    [Parameter(ParameterSetName='Change Colors')]
    [string]$PowerDraw2,

    [Parameter(ParameterSetName='Reset', Mandatory = $true)]
    [switch]$Reset = $false
)

$ErrorActionPreference = 'Stop' # Exit script on error.



####################################################################################################
##                                                                                                ##
##                                        Helper Functions                                        ##
##                                                                                                ##
####################################################################################################

function compare_byte_arrays
{
    param ( [byte[]]$a, [byte[]]$b )

    if ( $a.Length -ne $b.Length ) { return $false }

    for ($idx = 0; $idx -lt $a.Length; $idx++)
    {
        if ( $a[$idx] -ne $b[$idx] ) { return $false }
    }

    return $true
}

function get_word
{
    param ( [byte[]]$arr, [int]$offset )
    return $arr[$offset] -bor ([int]$arr[$offset + 1] -shl 8)
}

function set_word 
{
    param ( [byte[]]$arr, [int]$offset, [uint16]$word )

    $arr[$offset]     = $word -band 0xFF
    $arr[$offset + 1] = $word -shr 8
}



####################################################################################################
##                                                                                                ##
##                            Locate and open (rw) PCBS game logic DLL                            ##
##        steamapps\PC Building Simulator\PCBS_Data\Managed\Assembly-CSharp-firstpass.dll         ##
##                                                                                                ##
####################################################################################################

try
{
    if ( -not $PcbsDir )
    {
        # Find Steam
        $steam_dir = `
            Get-ItemProperty -Path Registry::HKEY_CURRENT_USER\SOFTWARE\Valve\Steam |
            Select-Object -ExpandProperty SteamPath

        $steam_library_db_file = [Path]::Combine($steam_dir, 'steamapps\libraryfolders.vdf')

        # Get all directories making up the Steam games library
        $steam_library_directories = `
            Get-Content $steam_library_db_file -Raw -Encoding UTF8 |
            Select-String '"path"\s+"([^"]+)"' -AllMatches |
            Select-Object -ExpandProperty Matches |
            % { $_.Groups[1] -replace '\\\\', '\' } # '\\' -> '\'
            #                                 ^^^ Normal string
            #                         ^^^^^^      Regex. \\ = Escaped backslash

        # Find PCBS among those directories
        $pcbs_install_directory = `
            $steam_library_directories |
            % { [Path]::Combine($_, 'steamapps\common\PC Building Simulator') } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
    }
    else
    {
        $pcbs_install_directory = $PcbsDir
    }

    $pcbs_target_path = [Path]::Combine($pcbs_install_directory, 'PCBS_Data\Managed\Assembly-CSharp-firstpass.dll')

    # Exclusively open game logic DLL in read/write mode
    $pcbs = [FileStream]::new(
        $pcbs_target_path, [FileMode]::Open, [FileAccess]::ReadWrite,
        [FileShare]::None, 4096, [FileOptions]::RandomAccess
    )
}
catch
{
    $error_message = 'Failed to locate or open PCBS.'
    if ( -not $PcbsDir )
    {
        $error_message += ' Consider using the -PcbsDir argument.'
    }

    Write-Error "$error_message`n$_"
}



####################################################################################################
##                                                                                                ##
##                      Offsets and data needed to patch the game logic DLL                       ##
##                                                                                                ##
####################################################################################################

$MemberRef_table = @{
    offset = 0x2342E8
    data = [byte[]]::new(0xF2D0)

    md5 = 0xFD, 0x42, 0x87, 0x42, 0x11, 0x28, 0x92, 0xF9, 0xE2, 0x60, 0xDA, 0x8A, 0x2B, 0x6E, 0x37, 0x5F
}

$OCCTApp_ctor = @{
    impl_offset = 0x101434
    data = [byte[]]::new(0x79)

    # MD5 hash of the ctor method body (excluding method header) with the color
    # RIDs (two bytes after call instructions) zeroed out.
    null_md5 = 0x10, 0xCC, 0xFD, 0xB9, 0xFB, 0x72, 0x73, 0x2F, 0x2E, 0x0C, 0x3A, 0xE8, 0x8B, 0x9E, 0xB3, 0x42

    color_offsets = @{
        cpu_temperature   = 0x0F
        cpu_throttled     = 0x20
        gpu_1_temperature = 0x31
        gpu_2_temperature = 0x42
        power_draw        = 0x53
    }
}

$color_rids = @{
    Black   = 0x04AA
    Blue    = 0x0C31
    Green   = 0x0DE0
    Cyan    = 0x0BE8
    Red     = 0x06F1
    Magenta = 0x106C
    Yellow  = 0x06F2
    White   = 0x049A
    Gray    = 0x106B
    Grey    = 0x106B
}

function get_color_name
{
    param ( [uint16]$rid )

    foreach ($entry in $color_rids.GetEnumerator())
    {
        if ($entry.Value -eq $rid)
        {
            return $entry.Key
        }
    }

    throw "Unknown color RID $rid"
}

function get_color_rid
{
    param ( [string]$color_name )

    $rid = $color_rids[$color_name]

    if ( $rid -ne $null ) { return $rid }
    else { throw "Unknown color name `"$color_name`"" }
}



####################################################################################################
##                                                                                                ##
##                                      Execute user command                                      ##
##                                                                                                ##
####################################################################################################

try
{
    #
    # Read game logic DLL and verify compatibility with this patch
    #

    # Read
    $pcbs.Seek($MemberRef_table.offset, [SeekOrigin]::Begin) | Out-Null
    $pcbs.Read($MemberRef_table.data, 0, $MemberRef_table.data.Length) | Out-Null

    $pcbs.Seek($OCCTApp_ctor.impl_offset, [SeekOrigin]::Begin) | Out-Null
    $pcbs.Read($OCCTApp_ctor.data, 0, $OCCTApp_ctor.data.Length) | Out-Null

    # Copy $OCCTApp_ctor.data so we can temporarily zero out certain bytes
    $OCCTApp_ctor_tmp = $OCCTApp_ctor.data.Clone()
    # Zero out all color RIDs in $OCCTApp_ctor_tmp to create an MD5 hash independent of the user's
    # current color settings.
    foreach ($offset in $OCCTApp_ctor.color_offsets.Values)
    {
        set_word  $OCCTApp_ctor_tmp  $offset  0
    }

    # Verify compatibility
    $MemberRef_table_md5 = [MD5]::Create().ComputeHash($MemberRef_table.data)
    $OCCTApp_ctor_null_md5 = [MD5]::Create().ComputeHash($OCCTApp_ctor_tmp)

    if (
        -not (compare_byte_arrays  $MemberRef_table_md5  $MemberRef_table.md5) `
        -or `
        -not (compare_byte_arrays  $OCCTApp_ctor_null_md5  $OCCTApp_ctor.null_md5)
    ) {
        throw "Your game's logic DLL is incompatible with this patch, sorry :("
    }



    #
    # Patch/parse $OCCT_ctor.data
    #

    $skip_write = $false

    switch ( $PsCmdLet.ParameterSetName )
    {
        'Change Colors'
        {
            if ( $CpuTemp )
            {
                set_word $OCCTApp_ctor.data `
                         $OCCTApp_ctor.color_offsets.cpu_temperature `
                         (get_color_rid $CpuTemp)
            }

            if ( $CpuThrottled )
            {
                set_word $OCCTApp_ctor.data `
                         $OCCTApp_ctor.color_offsets.cpu_throttled `
                         (get_color_rid $CpuThrottled)
            }

            if ( $GpuTemp1 )
            {
                set_word $OCCTApp_ctor.data `
                         $OCCTApp_ctor.color_offsets.gpu_1_temperature `
                         (get_color_rid $GpuTemp1)
            }

            if ( $GpuTemp2 -or $PowerDraw1 )
            {
                $tmp = if ( $PowerDraw1 ) { $PowerDraw1 } else { $GpuTemp2 }

                set_word $OCCTApp_ctor.data `
                         $OCCTApp_ctor.color_offsets.gpu_2_temperature `
                         (get_color_rid $tmp)
            }

            if ( $PowerDraw2 )
            {
                set_word $OCCTApp_ctor.data `
                         $OCCTApp_ctor.color_offsets.power_draw `
                         (get_color_rid $PowerDraw2)
            }
        }

        'Show Colors'
        {
            $skip_write = $true

            $cpu_temp      = get_color_name  (get_word  $OCCTApp_ctor.data  $OCCTApp_ctor.color_offsets.cpu_temperature)
            $cpu_throttled = get_color_name  (get_word  $OCCTApp_ctor.data  $OCCTApp_ctor.color_offsets.cpu_throttled)
            $gpu_1_temp    = get_color_name  (get_word  $OCCTApp_ctor.data  $OCCTApp_ctor.color_offsets.gpu_1_temperature)
            $gpu_2_temp    = get_color_name  (get_word  $OCCTApp_ctor.data  $OCCTApp_ctor.color_offsets.gpu_2_temperature)
            $power_draw    = get_color_name  (get_word  $OCCTApp_ctor.data  $OCCTApp_ctor.color_offsets.power_draw)

            Write-Host ''
            Write-Host "CPU temperature                  : $cpu_temp"
            Write-Host "CPU throttled                    : $cpu_throttled"
            Write-Host "GPU 1 temperature                : $gpu_1_temp"
            Write-Host "GPU 2 temperature / Power draw 1 : $gpu_2_temp"
            Write-Host "Power Draw 2                     : $power_draw"
            Write-Host ''
        }

        'Reset'
        {
            set_word $OCCTApp_ctor.data `
                     $OCCTApp_ctor.color_offsets.cpu_temperature `
                     (get_color_rid "blue")

            set_word $OCCTApp_ctor.data `
                     $OCCTApp_ctor.color_offsets.cpu_throttled `
                     (get_color_rid "cyan")

            set_word $OCCTApp_ctor.data `
                     $OCCTApp_ctor.color_offsets.gpu_1_temperature `
                     (get_color_rid "green")

            set_word $OCCTApp_ctor.data `
                     $OCCTApp_ctor.color_offsets.gpu_2_temperature `
                     (get_color_rid "gray")

            set_word $OCCTApp_ctor.data `
                     $OCCTApp_ctor.color_offsets.power_draw `
                     (get_color_rid "white")
        }
    }

    if ( -not $skip_write )
    {
        # Write modified $OCCTApp_ctor.data back to DLL
        $pcbs.Seek($OCCTApp_ctor.impl_offset, [SeekOrigin]::Begin) | Out-Null
        $pcbs.Write($OCCTApp_ctor.data, 0, $OCCTApp_ctor.data.Length) | Out-Null

        Write-Host "`nColors changed successfully`n"
    }
}
catch
{
    Write-Error $_
}
finally
{
    $pcbs.Close()
}
