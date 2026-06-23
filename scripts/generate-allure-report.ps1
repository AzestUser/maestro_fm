param(
    [string]$AllureCliPath
)

$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$resultsDir = Join-Path $PSScriptRoot "..\allure-results"
$reportRoot = Join-Path $PSScriptRoot "..\allure-report"
$recordingsRoot = Join-Path $PSScriptRoot "..\recordings"
$reportDir = Join-Path $reportRoot $timestamp
$recordingsDir = Join-Path $recordingsRoot $timestamp

$screenshotsRoot = Join-Path $PSScriptRoot "..\screenshots"
$flowsDir = Join-Path $PSScriptRoot "..\flows"

function Ensure-RunDirectories {
    param(
        [string]$ReportRoot,
        [string]$RecordingsRoot,
        [string]$ReportDir,
        [string]$RecordingsDir
    )

    New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $RecordingsRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    New-Item -ItemType Directory -Force -Path $RecordingsDir | Out-Null
}

Ensure-RunDirectories -ReportRoot $reportRoot -RecordingsRoot $recordingsRoot -ReportDir $reportDir -RecordingsDir $recordingsDir

function Get-AllureCommand {
    param(
        [string]$OverridePath
    )

    if ($OverridePath) {
        Write-Host "Checking override Allure path: $OverridePath"
        if (Test-Path $OverridePath) {
            $command = Get-Command $OverridePath -ErrorAction SilentlyContinue
            if ($command) {
                Write-Host "Found Allure executable at override path: $($command.Source)"
                return $command
            }
        }
        Write-Warning "Specified Allure path '$OverridePath' was not found or is not executable."
    }

    $candidates = @('allure','allure.exe','allure.bat','allure.cmd')
    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            Write-Host "Found Allure executable in PATH: $($command.Source)"
            return $command
        }
    }

    foreach ($candidate in $candidates) {
        $path = & where.exe $candidate 2>$null | Select-Object -First 1
        if ($path) {
            $command = Get-Command $path -ErrorAction SilentlyContinue
            if ($command) {
                Write-Host "Found Allure executable via where.exe: $($command.Source)"
                return $command
            }
        }
    }

    $installLocations = @(
        Join-Path $env:ProgramFiles 'allure*',
        Join-Path $env:ProgramFilesX86 'allure*',
        Join-Path $env:USERPROFILE 'scoop\apps\allure*',
        Join-Path $env:USERPROFILE 'AppData\Local\Programs\allure*',
        Join-Path $env:USERPROFILE 'AppData\Local\allure*'
    )

    foreach ($pattern in $installLocations) {
        $dirs = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
        foreach ($dir in $dirs) {
            $candidate = Join-Path $dir.FullName 'bin\allure.bat'
            if (Test-Path $candidate) {
                return Get-Command $candidate -ErrorAction SilentlyContinue
            }
            $candidate = Join-Path $dir.FullName 'bin\allure.exe'
            if (Test-Path $candidate) {
                return Get-Command $candidate -ErrorAction SilentlyContinue
            }
        }
    }

    return $null
}

$allureCommand = Get-AllureCommand -OverridePath $AllureCliPath
if (-not $allureCommand) {
    $allureCommand = Get-AllureCommand
}

if (-not $allureCommand) {
    Write-Error "Allure CLI is not installed or not available in PATH. Install Allure and rerun this script."
    exit 1
}

$allureExe = $allureCommand.Source

if (-not (Test-Path $resultsDir)) {
    Write-Error "Allure results directory not found: $resultsDir. Run tests with --format JUNIT first."
    exit 1
}

function Get-YamlSteps {
    param([string]$YamlPath, [string]$FlowsDir)
    if (-not (Test-Path $YamlPath)) { return @() }
    $lines = Get-Content $YamlPath -Encoding UTF8
    $steps = @()
    $inBody = $false
    foreach ($line in $lines) {
        if ($line.Trim() -eq '---') { $inBody = $true; continue }
        if (-not $inBody) { continue }
        if ($line -match '^- (.+)') {
            $stepName = $Matches[1].Trim()
            $subSteps = @()
            if ($stepName -match '^runFlow:\s*(.+)') {
                $subflowRelPath = $Matches[1].Trim()
                $subflowDir = Split-Path $YamlPath -Parent
                $subflowPath = Join-Path $subflowDir $subflowRelPath
                $subflowPath = [System.IO.Path]::GetFullPath($subflowPath)
                $subSteps = Get-YamlSteps -YamlPath $subflowPath -FlowsDir $FlowsDir
            }
            $steps += [pscustomobject]@{ name = $stepName; subSteps = $subSteps }
        }
    }
    return $steps
}

function Build-AllureSteps {
    param([array]$Steps, [long]$StartTime, [string]$FailureMessage, [ref]$FailedMarked)
    $result = @()
    $t = $StartTime
    foreach ($step in $Steps) {
        $subStepsBuilt = @()
        if ($step.subSteps -and $step.subSteps.Count -gt 0) {
            $subStepsBuilt = Build-AllureSteps -Steps $step.subSteps -StartTime $t -FailureMessage $FailureMessage -FailedMarked $FailedMarked
        }
        $stepStop = $t + 100
        if ($FailedMarked.Value) {
            $stepStatus = 'skipped'
        } elseif ($FailureMessage) {
            # Extract quoted value from step name: assertVisible: "Залишилось:" -> Залишилось:
            $stepKey = $step.name -replace '^\w+:\s*"?([^"]+)"?\s*$', '$1'
            if ($FailureMessage -match [regex]::Escape($stepKey)) {
                $stepStatus = 'failed'
                $FailedMarked.Value = $true
            } else {
                $stepStatus = 'passed'
            }
        } else {
            $stepStatus = 'passed'
        }
        $result += [pscustomobject]@{
            name = $step.name
            status = $stepStatus
            start = $t
            stop = $stepStop
            steps = $subStepsBuilt
            attachments = @()
            parameters = @()
            stepsCount = $subStepsBuilt.Count
            attachmentsCount = 0
            hasContent = ($subStepsBuilt.Count -gt 0)
            shouldDisplayMessage = $false
        }
        $t = $stepStop
    }
    return $result
}

function Get-ScreenshotForTest {
    param([string]$TestName, [string]$ScreenshotsRoot, [string]$YamlFileName)
    if (-not (Test-Path $ScreenshotsRoot)) { return $null }
    # Try matching by yaml file prefix (e.g. '02' from '02-cart.yaml')
    if ($YamlFileName -match '^(\d+)') {
        $prefix = $Matches[1]
        $match = Get-ChildItem -Path $ScreenshotsRoot -Filter "$prefix-*.png" -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    # Fallback: match by sanitized test name
    $nameBase = $TestName -replace '^\d+\s*-\s*', ''
    $nameBase = $nameBase -replace '[^\p{L}\p{N}\-_ ]', ''
    $nameBase = $nameBase.Trim() -replace '\s+', '-'
    $nameBase = $nameBase.ToLowerInvariant()
    $match = Get-ChildItem -Path $ScreenshotsRoot -Filter '*.png' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match [regex]::Escape($nameBase) } |
        Select-Object -First 1
    return $match?.FullName
}

function Sanitize-VideoFileName {
    param(
        [string]$TestName
    )
    $name = $TestName -replace '^\d+\s*-\s*', ''
    $name = $name -replace '[^\p{L}\p{N}\-_ ]', ''
    $name = $name.Trim() -replace '\s+', '-'
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'test-video'
    }
    return $name.ToLowerInvariant()
}

function Get-RecordingFileForTest {
    param(
        [string]$TestName,
        [string]$RecordingsRoot
    )

    $nameBase = Sanitize-VideoFileName -TestName $TestName
    $candidateNames = @(
        "$nameBase.mp4",
        "01-$nameBase.mp4",
        "02-$nameBase.mp4",
        "03-$nameBase.mp4",
        "smoke-all.mp4"
    )

    foreach ($candidate in $candidateNames) {
        $path = Join-Path $RecordingsRoot $candidate
        if (Test-Path $path) {
            return $path
        }
    }

    $match = Get-ChildItem -Path $RecordingsRoot -Filter '*.mp4' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match [regex]::Escape($nameBase) } |
        Select-Object -First 1
    return $match?.FullName
}

function Add-VideoAttachmentsToReport {
    param(
        [string]$RecordingsRoot,
        [string]$ReportDir,
        [string]$ResultsDir,
        [string]$FlowsDir,
        [string]$ScreenshotsRoot
    )

    $testCasesDir = Join-Path $ReportDir 'data\test-cases'
    $attachmentsDir = Join-Path $ReportDir 'data\attachments'
    New-Item -ItemType Directory -Force -Path $attachmentsDir | Out-Null

    $xmlFiles = Get-ChildItem -Path $ResultsDir -Filter '*.xml' | Sort-Object Name
    if (-not $xmlFiles) {
        Write-Warning "No JUnit XML files found in $ResultsDir. Skipping attachment injection."
        return
    }

    $recordingFiles = Get-ChildItem -Path $RecordingsRoot -Filter '*.mp4' -File -ErrorAction SilentlyContinue
    if (-not $recordingFiles) {
        Write-Warning "No recording files found in $RecordingsRoot."
    }

    $testCases = @()
    foreach ($xmlFile in $xmlFiles) {
        try {
            [xml]$xml = Get-Content $xmlFile.FullName -Raw
        } catch {
            Write-Warning "Failed to parse XML file $($xmlFile.FullName): $_"
            continue
        }

        $suiteNodes = @()
        if ($xml.testsuites) {
            $suiteNodes = @($xml.testsuites.testsuite)
        } elseif ($xml.testsuite) {
            $suiteNodes = @($xml.testsuite)
        }

        foreach ($suiteNode in $suiteNodes) {
            foreach ($case in @($suiteNode.testcase)) {
                if (-not $case -or -not $case.name) {
                    continue
                }
                $duration = 0.0
                if ($case.time) {
                    try {
                        $duration = [double]$case.time
                    } catch {
                        $duration = 0.0
                    }
                }
                $testCases += [pscustomobject]@{
                    Name = $case.name
                    Duration = $duration
                    FailureMessage = if ($case.failure) { 
                        if ($case.failure -is [string]) { $case.failure } else { $case.failure.InnerText }
                    } elseif ($case.error) { 
                        if ($case.error -is [string]) { $case.error } else { $case.error.InnerText }
                    } else { '' }
                }
            }
        }
    }

    foreach ($testCase in $testCases) {
        $testJsonFiles = Get-ChildItem -Path $testCasesDir -Filter '*.json'
        foreach ($file in $testJsonFiles) {
            try {
                $testJson = Get-Content $file.FullName -Raw | ConvertFrom-Json
            } catch {
                Write-Warning "Failed to parse Allure JSON file $($file.FullName): $_"
                continue
            }
            if ($testJson.name -ne $testCase.Name) { continue }

            if (-not $testJson.testStage) {
                $testJson.testStage = [pscustomobject]@{
                    steps = @(); attachments = @(); parameters = @()
                    hasContent = $false; attachmentsCount = 0; stepsCount = 0
                    attachmentStep = $false; shouldDisplayMessage = $false
                }
            }
            if (-not $testJson.testStage.attachments) { $testJson.testStage.attachments = @() }

            # --- Steps from yaml ---
            if ($FlowsDir) {
                $sanitized = Sanitize-VideoFileName -TestName $testCase.Name
                $yamlFile = Get-ChildItem -Path (Join-Path $FlowsDir 'smoke') -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match $sanitized -or (Get-Content $_.FullName -Raw) -match [regex]::Escape($testCase.Name) } |
                    Select-Object -First 1
                if ($yamlFile) {
                    $startMs = [long]($testJson.time.start)
                    if (-not $startMs) { $startMs = [long](Get-Date -UFormat %s) * 1000 }
                    $yamlSteps = Get-YamlSteps -YamlPath $yamlFile.FullName -FlowsDir $FlowsDir
                    $failedMarked = [ref]$false
                    $stepsArray = Build-AllureSteps -Steps $yamlSteps -StartTime $startMs -FailureMessage $testCase.FailureMessage -FailedMarked $failedMarked
                    Write-Host "Test '$($testCase.Name)' failure: '$($testCase.FailureMessage)'"
                    $testJson.testStage.steps = $stepsArray
                    $testJson.testStage.stepsCount = $stepsArray.Count
                }
            }

            # --- Video attachment (HTML player with base64) ---
            $videoPath = Get-RecordingFileForTest -TestName $testCase.Name -RecordingsRoot $RecordingsRoot
            if ($videoPath) {
                $videoFileName = Split-Path -Leaf $videoPath
                Copy-Item -Path $videoPath -Destination (Join-Path $attachmentsDir $videoFileName) -Force
                $videoBytes = [System.IO.File]::ReadAllBytes($videoPath)
                $videoBase64 = [System.Convert]::ToBase64String($videoBytes)
                $htmlFileName = [System.IO.Path]::GetFileNameWithoutExtension($videoFileName) + '.html'
                $htmlContent = "<!DOCTYPE html><html><body style='margin:0;background:#000'><video controls autoplay style='width:100%;max-height:100vh'><source src='data:video/mp4;base64,$videoBase64' type='video/mp4'></video></body></html>"
                Set-Content -Path (Join-Path $attachmentsDir $htmlFileName) -Value $htmlContent -Encoding utf8
                $testJson.testStage.attachments += [pscustomobject]@{ source = $htmlFileName; type = 'text/html'; name = 'Video recording' }
                Write-Host "Attached video $videoFileName to test '$($testCase.Name)'"
            } else {
                Write-Warning "No recording found for test '$($testCase.Name)'. Skipping video attachment."
            }

            # --- Screenshot attachment ---
            if ($ScreenshotsRoot) {
                $yamlFileName = if ($yamlFile) { $yamlFile.Name } else { '' }
                $screenshotPath = Get-ScreenshotForTest -TestName $testCase.Name -ScreenshotsRoot $ScreenshotsRoot -YamlFileName $yamlFileName
                if ($screenshotPath) {
                    $screenshotFileName = Split-Path -Leaf $screenshotPath
                    $imgBytes = [System.IO.File]::ReadAllBytes($screenshotPath)
                    $imgBase64 = [System.Convert]::ToBase64String($imgBytes)
                    $screenshotHtmlName = [System.IO.Path]::GetFileNameWithoutExtension($screenshotFileName) + '-screenshot.html'
                    $screenshotHtml = "<!DOCTYPE html><html><body style='margin:0;background:#000;display:flex;justify-content:center'><img src='data:image/png;base64,$imgBase64' style='max-width:100%;max-height:100vh'></body></html>"
                    Set-Content -Path (Join-Path $attachmentsDir $screenshotHtmlName) -Value $screenshotHtml -Encoding utf8
                    $testJson.testStage.attachments += [pscustomobject]@{ source = $screenshotHtmlName; type = 'text/html'; name = 'Screenshot' }
                    Write-Host "Attached screenshot $screenshotFileName to test '$($testCase.Name)'"
                } else {
                    Write-Warning "No screenshot found for test '$($testCase.Name)'."
                }
            }

            $testJson.testStage.attachmentsCount = $testJson.testStage.attachments.Count
            $testJson.testStage.hasContent = $true
            $testJson | ConvertTo-Json -Depth 10 | Set-Content -Path $file.FullName -Encoding utf8
            break
        }
    }
}

Write-Host "Generating Allure report from: $resultsDir"
Write-Host "Report output directory: $reportDir"
$generateOutput = & $allureExe generate $resultsDir -o $reportDir --clean 2>&1
$generateExit = $LASTEXITCODE
Write-Host $generateOutput
if ($generateExit -ne 0) {
    Write-Error "Allure report generation failed with exit code $generateExit."
    exit $generateExit
}

Write-Host "Allure report generated at: $reportDir"

$recordingFiles = Get-ChildItem -Path $recordingsRoot -Filter '*.mp4' -File -ErrorAction SilentlyContinue
if ($recordingFiles) {
    foreach ($source in $recordingFiles) {
        $destination = Join-Path $recordingsDir $source.Name
        Copy-Item -Path $source.FullName -Destination $destination -Force
    }
    Add-VideoAttachmentsToReport -RecordingsRoot $recordingsRoot -ReportDir $reportDir -ResultsDir $resultsDir -FlowsDir $flowsDir -ScreenshotsRoot $screenshotsRoot
} else {
    Write-Warning "No recording files found in $recordingsRoot. Skipping attachment injection."
    Add-VideoAttachmentsToReport -RecordingsRoot $recordingsRoot -ReportDir $reportDir -ResultsDir $resultsDir -FlowsDir $flowsDir -ScreenshotsRoot $screenshotsRoot
}

Write-Host "Opening Allure report..."
& $allureExe open $reportDir
