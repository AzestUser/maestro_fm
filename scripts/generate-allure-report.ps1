param(
    [string]$AllureCliPath
)

$ErrorActionPreference = "Stop"

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

function Fix-GarbledUTF8 {
    param([string]$Text)
    
    if (-not $Text) { return $Text }
    
    try {
        # Якщо текст містить mojibake (garbled UTF-8 as Latin-1), спробуємо його виправити
        # Конвертуємо текст назад через байти
        $bytes = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($Text)
        $fixedText = [System.Text.Encoding]::UTF8.GetString($bytes)
        
        # Перевіримо, чи виглядає результат краще
        # Використовуємо character codes замість直接 Cyrillic символів в regex
        if ($fixedText -match '[\u0430-\u044F\u0456\u0457\u0454\u0491\u0410-\u0429\u0406\u0407\u0404\u0490]') {
            return $fixedText
        }
    } catch {
        # Якщо конверсія не сработала, повертаємо оригінальний текст
    }
    
    return $Text
}

function Get-YamlSteps {
    param([string]$YamlPath, [string]$FlowsDir)
    if (-not (Test-Path $YamlPath)) { return @() }
    # Read YAML with explicit UTF-8 encoding
    $lines = [System.IO.File]::ReadAllLines($YamlPath, [System.Text.Encoding]::UTF8)
    $steps = @()
    $inBody = $false
    foreach ($line in $lines) {
        if ($line.Trim() -eq '---') { $inBody = $true; continue }
        if (-not $inBody) { continue }
        if ($line -match '^- (.+)') {
            $stepName = $Matches[1].Trim()
            # Fix garbled UTF-8 in step names
            $stepName = Fix-GarbledUTF8 -Text $stepName
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
    $stepDuration = 1000  # 1 second per step
    foreach ($step in $Steps) {
        $subStepsBuilt = @()
        if ($step.subSteps -and $step.subSteps.Count -gt 0) {
            $subStepsBuilt = Build-AllureSteps -Steps $step.subSteps -StartTime $t -FailureMessage $FailureMessage -FailedMarked $FailedMarked
            # Calculate actual duration from substeps
            if ($subStepsBuilt.Count -gt 0) {
                $lastSubstep = $subStepsBuilt[-1]
                $stepDuration = $lastSubstep.stop - $t
            }
        }
        $stepStop = $t + $stepDuration
        $stepStatus = 'passed'
        
        if (-not $FailedMarked.Value -and $FailureMessage) {
            # Extract the step key (e.g., "До Акцій" from "tapOn: \"До Акцій\"")
            $stepKey = $step.name -replace '^[^:]+:\s*"?([^"]+)"?.*$', '$1'
            $stepKey = $stepKey.Trim()
            
            # Compare using proper UTF-8 encoding with StringComparison
            $comparisonResult = [System.Globalization.CultureInfo]::InvariantCulture.CompareInfo.IndexOf($FailureMessage, $stepKey, [System.Globalization.CompareOptions]::IgnoreCase)
            if ($comparisonResult -ge 0) {
                $stepStatus = 'failed'
                $FailedMarked.Value = $true
            }
        } elseif ($FailedMarked.Value) {
            $stepStatus = 'skipped'
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
    # Fallback: match by sanitized test name (using same logic as video file matching)
    $nameBase = Sanitize-VideoFileName -TestName $TestName
    $match = Get-ChildItem -Path $ScreenshotsRoot -Filter "$nameBase.png" -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($match) { return $match.FullName }
    # Another fallback: search by partial match
    $match = Get-ChildItem -Path $ScreenshotsRoot -Filter '*.png' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match [regex]::Escape($nameBase) } |
        Select-Object -First 1
    if ($match) { return $match.FullName }
    # Handle web prefix: try with "web-" prefix
    if ($TestName -match 'web' -or $TestName -match 'Web') {
        $match = Get-ChildItem -Path $ScreenshotsRoot -Filter "web-*.png" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match [regex]::Escape($nameBase) } |
            Select-Object -First 1
        if ($match) { return $match.FullName }
        # Try prefix match: web-01-launch for "smoke-launch-app"
        $prefix = if ($YamlFileName -match '^(\d+)') { $Matches[1] } else { $null }
        if ($prefix) {
            $match = Get-ChildItem -Path $ScreenshotsRoot -Filter "web-$prefix-*.png" -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($match) { return $match.FullName }
        }
    }
    return $null
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

    Write-Host "Searching for video for test: $TestName in $RecordingsRoot"
    $nameBase = Sanitize-VideoFileName -TestName $TestName
    Write-Host "Sanitized name base: $nameBase"
    $candidateNames = @(
        "$nameBase.mp4",
        "01-$nameBase.mp4",
        "02-$nameBase.mp4",
        "03-$nameBase.mp4",
        "smoke-all.mp4"
    )

    # First search in subdirectories (mobile/, web/)
    foreach ($subDir in @('mobile', 'web')) {
        $subPath = Join-Path $RecordingsRoot $subDir
        Write-Host "Checking subpath: $subPath"
        if (Test-Path $subPath) {
            foreach ($candidate in $candidateNames) {
                $path = Join-Path $subPath $candidate
                Write-Host "  Checking: $path"
                if (Test-Path $path) {
                    Write-Host "  Found: $path"
                    return $path
                }
            }
            $match = Get-ChildItem -Path $subPath -Filter '*.mp4' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match [regex]::Escape($nameBase) } |
                Select-Object -First 1
            if ($match) { 
                Write-Host "  Found via regex: $($match.FullName)"
                return $match.FullName 
            }
        }
    }

    # Fallback to root recordings directory
    Write-Host "Checking root recordings directory"
    foreach ($candidate in $candidateNames) {
        $path = Join-Path $RecordingsRoot $candidate
        Write-Host "  Checking: $path"
        if (Test-Path $path) {
            Write-Host "  Found: $path"
            return $path
        }
    }

    $match = Get-ChildItem -Path $RecordingsRoot -Filter '*.mp4' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match [regex]::Escape($nameBase) } |
        Select-Object -First 1
    if ($match) {
        Write-Host "  Found via regex in root: $($match.FullName)"
        return $match.FullName
    }
    Write-Host "  No video found"
    return $null
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
            # Read with explicit UTF-8 encoding - use System.IO for more reliable handling
            $xmlContent = [System.IO.File]::ReadAllText($xmlFile.FullName, [System.Text.Encoding]::UTF8)
            [xml]$xml = $xmlContent
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
                
                # Ensure failure message is properly handled as UTF-8
                $failureMsg = ''
                if ($case.failure) { 
                    if ($case.failure -is [string]) { 
                        $failureMsg = $case.failure 
                    } else { 
                        $failureMsg = $case.failure.InnerText 
                    }
                } elseif ($case.error) { 
                    if ($case.error -is [string]) { 
                        $failureMsg = $case.error 
                    } else { 
                        $failureMsg = $case.error.InnerText 
                    }
                }
                
                # Fix garbled UTF-8 if needed
                $failureMsg = Fix-GarbledUTF8 -Text $failureMsg
                
                $testCases += [pscustomobject]@{
                    Name = $case.name
                    Duration = $duration
                    FailureMessage = $failureMsg
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
                # Search in both mobile and web smoke directories
                $yamlFile = $null
                foreach ($subDir in @('mobile\smoke', 'web\smoke', 'smoke')) {
                    $searchPath = Join-Path $FlowsDir $subDir
                    if (Test-Path $searchPath) {
                        $found = Get-ChildItem -Path $searchPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match $sanitized -or (Get-Content $_.FullName -Raw) -match [regex]::Escape($testCase.Name) } |
                            Select-Object -First 1
                        if ($found) {
                            $yamlFile = $found
                            break
                        }
                    }
                }
                if ($yamlFile) {
                    $startMs = $null
                    if ($testJson.time -and $testJson.time.start) {
                        try { $startMs = [long]$testJson.time.start } catch { $startMs = $null }
                    }
                    if (-not $startMs) {
                        $startMs = [long]([DateTimeOffset]::Now.ToUnixTimeMilliseconds())
                    }
                    $yamlSteps = Get-YamlSteps -YamlPath $yamlFile.FullName -FlowsDir $FlowsDir
                    $failedMarked = [ref]$false
                    $stepsArray = Build-AllureSteps -Steps $yamlSteps -StartTime $startMs -FailureMessage $testCase.FailureMessage -FailedMarked $failedMarked
                    Write-Host "Test '$($testCase.Name)' failure: '$($testCase.FailureMessage)'"

                    # Capture last step stop in milliseconds
                    $lastStepStopMs = $null
                    if ($stepsArray -and $stepsArray.Count -gt 0) { $lastStepStopMs = [long]$stepsArray[-1].stop }

                    $testJson.testStage.steps = $stepsArray
                    $testJson.testStage.stepsCount = $stepsArray.Count

                    # Ensure top-level numeric start/stop timestamps exist so Allure UI can show step times
                    # Compute stopMs: prefer original duration-based stop, but ensure it covers last step
                    # Compute stop in milliseconds by taking max(original stop, last step stop)
                    $origStop = $null
                    if ($testJson.time -and $testJson.time.duration) {
                        try { $dur = [long]$testJson.time.duration; $origStop = [long]($startMs + $dur) } catch { $origStop = $null }
                    }

                    if ($origStop -and $lastStepStopMs) {
                        $stopMs = [long]([Math]::Max($origStop, $lastStepStopMs))
                    } elseif ($origStop) {
                        $stopMs = [long]$origStop
                    } elseif ($lastStepStopMs) {
                        $stopMs = [long]$lastStepStopMs
                    } else {
                        $stopMs = [long]$startMs
                    }

                    # Write test-level times in milliseconds (Allure default)
                    $newTime = @{ start = [long]$startMs; stop = [long]$stopMs }
                    $newTime.duration = [long]($newTime.stop - $newTime.start)

                    # Replace the time object with a simple hashtable so properties are writable
                    $testJson.time = $newTime
                }
            }

            # --- Video attachment (HTML player with base64) ---
            $videoPath = Get-RecordingFileForTest -TestName $testCase.Name -RecordingsRoot $RecordingsRoot
            if ($videoPath) {
                $videoFileName = Split-Path -Leaf $videoPath
                # Use subdirectory name as prefix (e.g., "mobile-smoke---launch-app.mp4")
                $parentDir = Split-Path -Leaf (Split-Path $videoPath -Parent)
                $prefix = if ($parentDir -in @('mobile', 'web')) { "$parentDir-" } else { "" }
                $newVideoFileName = $prefix + $videoFileName
                $destVideoPath = Join-Path $attachmentsDir $newVideoFileName
                Copy-Item -Path $videoPath -Destination $destVideoPath -Force
                $videoBytes = [System.IO.File]::ReadAllBytes($videoPath)
                $videoBase64 = [System.Convert]::ToBase64String($videoBytes)
                $htmlFileName = [System.IO.Path]::GetFileNameWithoutExtension($newVideoFileName) + '.html'
                $htmlContent = "<!DOCTYPE html><html><body style='margin:0;background:#000'><video controls autoplay style='width:100%;max-height:100vh'><source src='data:video/mp4;base64,$videoBase64' type='video/mp4'></video></body></html>"
                Set-Content -Path (Join-Path $attachmentsDir $htmlFileName) -Value $htmlContent -Encoding utf8
                $testJson.testStage.attachments += [pscustomobject]@{ source = $htmlFileName; type = 'text/html'; name = 'Video recording' }
                Write-Host "Attached video $newVideoFileName to test '$($testCase.Name)'"
            } else {
                Write-Warning "No recording found for test '$($testCase.Name)'. Skipping video attachment."
            }

            # --- Screenshot attachment ---
            if ($ScreenshotsRoot) {
                $yamlFileName = if ($yamlFile) { $yamlFile.Name } else { '' }
                
                # Determine platform (mobile or web)
                $platform = ""
                if ($testCase.Name -match 'Mobile' -or $testCase.Name -match 'mobile') {
                    $platform = "mobile"
                } elseif ($testCase.Name -match 'Web' -or $testCase.Name -match 'web') {
                    $platform = "web"
                }
                
                # Get ALL screenshots matching platform and test number
                $screenshotPattern = ""
                if ($yamlFileName -match '^(\d+)') {
                    $prefix = $Matches[1]
                    # Build pattern: "mobile-01-*" or "web-01-*"
                    if ($platform) {
                        $screenshotPattern = "$platform-$prefix-*.png"
                    } else {
                        $screenshotPattern = "$prefix-*.png"
                    }
                } else {
                    $nameBase = Sanitize-VideoFileName -TestName $testCase.Name
                    if ($platform) {
                        $screenshotPattern = "$platform-$nameBase*.png"
                    } else {
                        $screenshotPattern = "$nameBase*.png"
                    }
                }
                
                Write-Host "Searching for screenshots with pattern: $screenshotPattern in $ScreenshotsRoot"
                $screenshots = Get-ChildItem -Path $ScreenshotsRoot -Filter $screenshotPattern -File -ErrorAction SilentlyContinue
                
                if ($screenshots) {
                    if ($screenshots -is [Array]) {
                        $screenshots = $screenshots | Sort-Object Name
                    } else {
                        $screenshots = @($screenshots)
                    }
                    
                    foreach ($screenshotPath in $screenshots) {
                        $screenshotFileName = $screenshotPath.Name
                        $imgBytes = [System.IO.File]::ReadAllBytes($screenshotPath.FullName)
                        $imgBase64 = [System.Convert]::ToBase64String($imgBytes)
                        $screenshotHtmlName = [System.IO.Path]::GetFileNameWithoutExtension($screenshotFileName) + '-screenshot.html'
                        $screenshotHtml = "<!DOCTYPE html><html><body style='margin:0;background:#000;display:flex;justify-content:center'><img src='data:image/png;base64,$imgBase64' style='max-width:100%;max-height:100vh'></body></html>"
                        Set-Content -Path (Join-Path $attachmentsDir $screenshotHtmlName) -Value $screenshotHtml -Encoding utf8
                        $testJson.testStage.attachments += [pscustomobject]@{ source = $screenshotHtmlName; type = 'text/html'; name = "Screenshot: $screenshotFileName" }
                        Write-Host "Attached screenshot $screenshotFileName to test '$($testCase.Name)'"
                    }
                } else {
                    Write-Warning "No screenshots found for test '$($testCase.Name)'. Pattern: $screenshotPattern"
                }
            }

            $testJson.testStage.attachmentsCount = $testJson.testStage.attachments.Count
            $testJson.testStage.hasContent = $true
            
            # Fix: Ensure numbers are serialized as numbers, not strings
            $jsonOutput = $testJson | ConvertTo-Json -Depth 10
            
            # Manually fix any string numbers that should be actual numbers
            $jsonOutput = $jsonOutput -replace '"start":\s*"(\d+)"', '"start": $1'
            $jsonOutput = $jsonOutput -replace '"stop":\s*"(\d+)"', '"stop": $1'
            $jsonOutput = $jsonOutput -replace '"stepsCount":\s*"(\d+)"', '"stepsCount": $1'
            $jsonOutput = $jsonOutput -replace '"attachmentsCount":\s*"(\d+)"', '"attachmentsCount": $1'
            
            Set-Content -Path $file.FullName -Value $jsonOutput -Encoding utf8
            Write-Host "Updated test case: $($testCase.Name) with UTF-8 encoding"
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

if (-not $env:SKIP_ALLURE_OPEN) {
    Write-Host "Opening Allure report..."
    & $allureExe open $reportDir
} else {
    Write-Host "Environment variable SKIP_ALLURE_OPEN is set; skipping opening the report."
}
