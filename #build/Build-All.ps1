Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = "SilentlyContinue" # https://www.amido.com/powershell-win32-error-handle-invalid-0x6/

# Write-Host, Write-Error and Write-Warning do not function properly in Azure
# So this mostly uses Write-Output for now
$BuildRoslynBranch = Resolve-Path "$PSScriptRoot\Build-RoslynBranch.ps1"
."$PSScriptRoot\Setup-Build.ps1"

function Update-RoslynSource($directoryPath, $repositoryUrl) {
    Write-Output "Updating $directoryPath"
    if (Test-Path "$directoryPath\.git") {
        Invoke-Git $directoryPath config user.email "tryroslyn@github.test"
        Invoke-Git $directoryPath config user.name "TryRoslyn"
        Invoke-Git $directoryPath fetch --prune origin
    }
    else {
        Invoke-Git . clone $repositoryUrl $directoryPath
    }
}

function Format-Xml($xml) {
    $stringWriter = New-Object IO.StringWriter

    $xmlWriter = New-Object Xml.XmlTextWriter $stringWriter
    $xmlWriter.Formatting = [Xml.Formatting]::Indented
    $xml.WriteTo($xmlWriter)
    $xmlWriter.Flush()

    return $stringWriter.ToString()
}

function Get-Package-Version($path, $lib) {
    $content = [IO.File]::ReadAllText((Resolve-Path $path))
    $json = $content | ConvertFrom-Json
    return $json.dependencies.$lib
}

function Rewrite-Package-Version($packagesPath, $map) {
    $content = [IO.File]::ReadAllText((Resolve-Path $packagesPath))
    $contentXml = [xml]$content
    $map.GetEnumerator() | % {
        $name = $_.Key
        $version = $_.Value
        Select-Xml $contentXml -XPath '//package' |
            ? { $_.Node.id -match "^$([regex]::Escape($name))" } |
            % { $_.Node.version = $version }
    }
    $rewritten = Format-Xml $contentXml
    if ($rewritten -eq $content) {
        return
    }
    Set-Content $packagesPath $rewritten
}

function Rewrite-ProjectReferences($projectPath, $map) {
    $xmlNamespaces = @{msbuild='http://schemas.microsoft.com/developer/msbuild/2003'}

    $content = [IO.File]::ReadAllText((Resolve-Path $projectPath))
    $contentXml = [xml]$content
    $map.GetEnumerator() | % {
        $name = $_.Key
        $path = $_.Value
        Select-Xml -Xml $contentXml -XPath '//msbuild:Reference' -Namespace $xmlNamespaces |
            ? { $_.Node.Include -match "^$([regex]::Escape($name))(,|$)" } |
            % {
                $_.Node.Include = $name
                @(Select-Xml -Xml $_.Node -XPath 'descendant::msbuild:HintPath' -Namespace $xmlNamespaces)[0].Node.InnerText = $path
            }
    }

    $rewritten = Format-Xml $contentXml
    if ($rewritten -eq $content) {
        return
    }
    Set-Content $projectPath $rewritten
}

function Ensure-ResolvedPath($path) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType directory -Path $path | Out-Null    
    }
    return Resolve-Path $path
}

function ConvertTo-Hashtable([PSCustomObject] $object) {
    $result = @{}
    $object.PSObject.Properties | % { $result[$_.Name] = $_.Value }    
    return $result
}

# Code ------
try {
    $Host.UI.RawUI.WindowTitle = "TryRoslyn Build" # prevents title > 1024 char errors

    #Write-Output "Killing VBCSCompiler instances"
    #taskkill /IM VBCSCompiler.exe /F
    
    Write-Output "Environment:"
    Write-Output "  Current Path:       $(Get-Location)"    
    Write-Output "  Script Root:        $PSScriptRoot"

    $root = Resolve-Path "$PSScriptRoot\.."
    Write-Output "  Root:               $root"

    $sourceRoot = Resolve-Path "$root\source"
    Write-Output "  Source Root:        $sourceRoot"

    $roslynBuildRoot = Ensure-ResolvedPath "$root\!roslyn"
    Write-Output "  Roslyn Build Root:  $roslynBuildRoot"

    $sitesBuildRoot = Ensure-ResolvedPath "$root\!sites"
    Write-Output "  Sites Build Root:   $sitesBuildRoot"   

    $buildConfig = ConvertFrom-Json (Get-Content "$root\Build.config.json" -Raw)

    ${env:$HOME} = $PSScriptRoot
    Invoke-Git . --version

    Write-Output "Restoring TryRoslyn packages..."
    &"$PSScriptRoot\#tools\nuget" restore "$sourceRoot\TryRoslyn.sln"

    $failedListPath = "$sitesBuildRoot\!failed.txt"
    if (Test-Path $failedListPath) {
        Write-Output "Deleting $failedListPath..."
        Remove-Item $failedListPath
    }

    $buildConfig.RoslynRepositories | % {
        Write-Output "Building repository '$($_.Name)' ($($_.Url))..."
        $roslynSourceRoot = Ensure-ResolvedPath "$roslynBuildRoot\$($_.Name)"
        Write-Output "  Roslyn Source Root: $roslynSourceRoot"

        Write-Output "Updating..."
        Update-RoslynSource -DirectoryPath $roslynSourceRoot -RepositoryUrl $($_.Url)

        Write-Output "Getting branches..."
        $branchesRaw = @(Invoke-Git $roslynSourceRoot branch --remote)
        $branches = $branchesRaw |
            ? { $_ -notmatch '^\s+origin/HEAD' } |
            % { ($_ -match 'origin/(.+)$') | Out-Null; $matches[1] }
        
        $repositoryConfig = ConvertTo-Hashtable $_
        $repositoryName = $repositoryConfig.Name
        $include = $repositoryConfig['Include']
        $exclude = $repositoryConfig['Exclude']
        
        Write-Output "  $branches"
        $branches | % {
            Write-Output ''
            Write-Output "*** $repositoryName`: $_"
            if ($include -and $_ -notmatch $include) {
                Write-Output "Does not match inclusion rules, skipped."
                return
            }
            if ($exclude -and $_ -match $exclude) {
                Write-Output "Matches exclusion rule, skipped."
                return
            }

            $Host.UI.RawUI.WindowTitle = "TryRoslyn Build: $_"
            $branchFsName = $repositoryName + "-" + ($_ -replace '[/\\:]', '-')
            
            $siteBuildRoot     = Ensure-ResolvedPath "$sitesBuildRoot\$branchFsName"
            $roslynBinaryRoot  = Ensure-ResolvedPath "$siteBuildRoot\!roslyn"
            $siteBuildTempRoot = Ensure-ResolvedPath "$siteBuildRoot\!temp"
            $siteCopyRoot      = Ensure-ResolvedPath "$siteBuildRoot\!site"

            try {
                Write-Output "  Copying $sourceRoot => $siteBuildRoot"
                robocopy $sourceRoot $siteBuildRoot /njh /njs /ndl /np /ns /xo /e /purge `
                    /xd "$roslynBinaryRoot" "$siteCopyRoot" "$siteBuildTempRoot" "$sourceRoot\Web"
                Write-Output ""

                Push-Location $roslynBuildRoot
                try {
                    &$BuildRoslynBranch -SourceRoot $roslynSourceRoot -BranchName $_ -OutputRoot $roslynBinaryRoot
                }
                finally {
                    Pop-Location
                }

                Write-Output "Getting branch info..."
                $branchInfo = @{
                    name    = $_
                    repository = $repositoryConfig.Name
                    commits = @(@{
                        hash    =  (Invoke-Git $roslynSourceRoot log "$_" -n 1 --pretty=format:"%H" )
                        date    =  (Invoke-Git $roslynSourceRoot log "$_" -n 1 --pretty=format:"%aI")
                        author  =  (Invoke-Git $roslynSourceRoot log "$_" -n 1 --pretty=format:"%aN")
                        message = @(Invoke-Git $roslynSourceRoot log "$_" -n 1 --pretty=format:"%B" ) -join "`r`n"
                    })
                }
                Set-Content "$roslynBinaryRoot\!BranchInfo.json" (ConvertTo-Json $branchInfo -Depth 100)

                Push-Location $siteBuildRoot
                try {
                    $buildLogPath = "$siteBuildRoot\!build.log"

                    $map = @{
                            'Microsoft.CodeAnalysis'             = "$roslynBinaryRoot\Microsoft.CodeAnalysis.dll"
                            'Microsoft.CodeAnalysis.CSharp'      = "$roslynBinaryRoot\Microsoft.CodeAnalysis.CSharp.dll"
                            'Microsoft.CodeAnalysis.VisualBasic' = "$roslynBinaryRoot\Microsoft.CodeAnalysis.VisualBasic.dll"
                        }
                    $packagesMap = @{}
                    $metadataDependencyJsonPath = "$($roslynSourceRoot)\src\Dependencies\Metadata\project.json"
                    if (Test-Path $metadataDependencyJsonPath) {
                        $metadataVersion = Get-Package-Version $metadataDependencyJsonPath "System.Reflection.Metadata"
                        Write-Output "System.Reflection.Metadata $($metadataVersion)"
                        $map['System.Reflection.Metadata'] = "..\#packages\System.Reflection.Metadata.$($metadataVersion)\lib\portable-net45+win8\System.Reflection.Metadata.dll"
                        $packagesMap['System.Reflection.Metadata'] = $metadataVersion
                    }
                    Write-Output "Rewriting *.csproj files..."
                    Get-ChildItem *.csproj -Recurse -ErrorAction SilentlyContinue | % {
                        Rewrite-ProjectReferences $_ $map
                        Write-Output "  $($_.Name)"
                    }
                    
                    Write-Output "Rewriting packages.congig files..."
                    Get-ChildItem packages.config -Recurse -ErrorAction SilentlyContinue | % {
                        Rewrite-Package-Version $_ $packagesMap
                    }
                    
                    Write-Output "Restoring site packages..."
                    &"$PSScriptRoot\#tools\nuget" restore "$siteBuildRoot\TryRoslyn.sln"

                    Write-Output "Building Web.Api.csproj..."
                    &$MSBuild Web.Api\Web.Api.csproj > $buildLogPath `
                        /p:OutputPath="""$siteCopyRoot\bin\\""" `
                        /p:IntermediateOutputPath="""$siteBuildTempRoot\\""" `
                        /p:AllowedReferenceRelatedFileExtensions=.pdb

                    if ($LastExitCode -ne 0) {
                        throw New-Object BranchBuildException("Build failed, see $buildLogPath", $buildLogPath)
                    }

                    Copy-Item "Web.Api\Global.asax" "$siteCopyRoot\Global.asax" -Force
                    Copy-Item "Web.Api\Web.config" "$siteCopyRoot\Web.config" -Force
                    Write-Output "TryRoslyn build done."
                }
                finally {
                    Pop-Location
                }
            }
            catch {
                $ex = $_.Exception
                if ($ex -isnot [BranchBuildException]) {
                    throw
                }

                Write-Output "  [WARNING] $($ex.Message)"
                Add-Content $failedListPath @("$branchFsName ($repositoryName)", $ex.Message, '')
            }
        }
    }
}
catch {
    Write-Output "[ERROR] $_"
    Write-Output 'Returning exit code 1'
    exit 1
}