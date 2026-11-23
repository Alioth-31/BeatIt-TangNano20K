param(
    [Parameter(Mandatory)] [string]$Port,
    [int]$Location,
    [int]$CableIndex = 1,
    [string]$CalibrationProfile = '',
    [switch]$SkipProgram,
    [switch]$BareBoard
)

$ErrorActionPreference = 'Stop'
$beatitRoot = Split-Path -Parent $PSScriptRoot
$beatitPython = (Get-Command python -CommandType Application).Source
Push-Location -LiteralPath $beatitRoot
try {
    if (-not $SkipProgram) {
        if (-not $PSBoundParameters.ContainsKey('Location')) {
            throw 'Use program_sram.py --list and pass the reported USB location with -Location.'
        }
        $beatitProfile = @('--app', '--transport', 'usb', '--voices', '32',
            '--performance', '--mono', '--guide', '--peripherals',
            '--tremolo', '--delay', '--reverb', '--dc-block')
        if ($BareBoard) { $beatitProfile += '--no-controls' }
        else { $beatitProfile += '--hdmi' }
        & $beatitPython -u -X utf8 scripts/program_sram.py @beatitProfile `
            --location $Location --cable-index $CableIndex --bridge-port $Port --verify
        if ($LASTEXITCODE -ne 0) { throw 'SRAM programming/verification failed; inspect programmer output.' }
    }
    if ($CalibrationProfile) {
        & $beatitPython -u -X utf8 scripts/hardware_ready.py --port $Port --require-idle --profile $CalibrationProfile apply
    } else {
        & $beatitPython -u -X utf8 scripts/hardware_ready.py --port $Port --require-idle check
    }
    if ($LASTEXITCODE -ne 0) { throw 'Hardware inspection or calibration restore failed; inspect build/hardware-ready/report.json.' }
} finally {
    Pop-Location
}
