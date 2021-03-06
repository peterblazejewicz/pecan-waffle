﻿[cmdletbinding()]
param(
    $nugetPsMinModuleVersion = '0.2.1.1'
)

$global:pecanwafflesettings = New-Object -TypeName psobject -Property @{
    TempDir = [System.IO.DirectoryInfo]('{0}\pecan-waffle\temp\projtemplates' -f $env:LOCALAPPDATA)
    Templates = @()
    TemplateSources = @()
    EnableAddLocalSourceOnLoad = $true
}
# todo: enable overriding settings via env var

function InternalGet-ScriptDirectory{
    split-path (((Get-Variable MyInvocation -Scope 1).Value).MyCommand.Path)
}

function Internal-HasProperty{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [ValidateNotNull()]
        $inputObject,

        [Parameter(Position=1,Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$propertyName
    )
    process{
        [bool]($inputObject.PSObject.Properties.name -match ('^{0}$' -f $propertyName))
    }
}

function Internal-AddProperty{
    [cmdletbinding()]
    param(
        [Parameter(Position=1,Mandatory=$true)]
        [ValidateNotNull()]
        $inputObject,

        [Parameter(Position=2,Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$propertyName,

        [Parameter(Position=3,Mandatory=$true)]
        $propertyValue
    )
    process{
        $inputObject | Add-Member -MemberType NoteProperty -Name $propertyName -Value $propertyValue
    }
}

function InternalGet-NewTempDir{
    [cmdletbinding()]
    param()
    process{
        if(-not (Test-Path $global:pecanwafflesettings.TempDir)){
            New-Item -ItemType Directory -Path ($global:pecanwafflesettings.TempDir.FullName) | Out-Null
        }

        [System.IO.DirectoryInfo]$newpath = Join-Path ($global:pecanwafflesettings.TempDir.FullName) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $newpath.FullName | out-null
        # return the fullpath
        $newpath.FullName
    }
}

# Items related to template sources

function Add-TemplateSource{
    [cmdletbinding(DefaultParameterSetName='local')]
    param(
        [Parameter(Position=0,Mandatory=$true,ParameterSetName='local')]
        [System.IO.DirectoryInfo]$path,

        [Parameter(Position=1,Mandatory=$true,ParameterSetName='git')]
        [ValidateNotNullOrEmpty()]
        [string]$url,

        [Parameter(Position=2,ParameterSetName='git')]
        $branch = 'master',

        [Parameter(Position=3,ParameterSetName='git')]
        [System.IO.DirectoryInfo]$localfolder = ('{0}\pecan-waffle\remote\templates' -f $env:LOCALAPPDATA),

        [Parameter(Position=4,ParameterSetName='git')]
        [string]$repoName
    )
    process{
        [string]$localpath = $null

        if($path -ne $null){
            if(-not [System.IO.Path]::IsPathRooted($path)){
                $path = (Join-Path $pwd $path)
            }
            [string]$localpath = $path.FullName
        }
        else{
            if(-not (Test-Path $localfolder)){
                New-Item -Path $localfolder.FullName -ItemType Directory
            }

            $oldPath = Get-Location

            if([string]::IsNullOrWhiteSpace($repoName)){
                $startIndex = $url.LastIndexOf('/')
                [string]$repoName = [System.Guid]::NewGuid()
                if($startIndex -gt 0){
                    $repoName = $url.Substring($startIndex +1).Replace('.git','')
                }
            }

            [System.IO.DirectoryInfo]$repoFolder = (Join-Path $localfolder.FullName $repoName)
            $path =([System.IO.DirectoryInfo]$repoFolder).FullName
            try{
                Set-Location $localfolder

                if(-not (Test-Path $repoFolder.FullName)){
                    Import-NuGetPowershell
                    Execute-CommandString "git clone $url --branch $branch --single-branch $repoName"
                }
            }
            finally{
                Set-Location $oldPath
            }
        }

        $files = (Get-ChildItem -Path $path 'pw-templateinfo*.ps1' -Recurse -File -Exclude '.git','node_modules','bower_components' -ErrorAction SilentlyContinue)
        foreach($file in $files){
            & ([System.IO.FileInfo]$file.FullName)
        }

        $templateSource = New-Object -TypeName psobject -Property @{
            LocalFolder = $repoFolder.FullName
            Url = $url
        }

        $global:pecanwafflesettings.TemplateSources += $templateSource
    }
}

function Show-Templates{
    [cmdletbinding()]
    param()
    process{
        $Global:pecanwafflesettings.Templates | Select-Object -Property Name,Type | Sort-Object -Property Type,Name,Description
    }
}

function Update-RemoteTemplates{
    [cmdletbinding()]
    param()
    process{
        foreach($ts in $global:pecanwafflesettings.TemplateSources){
            if( -not ([string]::IsNullOrWhiteSpace($ts.Url)) -and (Test-Path $ts.LocalFolder)){
                $oldpath = Get-Location
                try{
                    Set-Location $ts.LocalFolder
                    Import-NuGetPowershell
                    Execute-CommandString "git pull"
                }
                finally{
                    Set-Location $oldpath
                }
            }
        }
    }
}

# Item Related to Templates Below
function New-ItemTemplate{
    [cmdletbinding()]
    param(
        [Parameter(Position=0)]
        $sharedInfo
    )
    process{
        # copy the shared info
        $newtemplate = new-object psobject
        $sharedInfo.psobject.properties | % {
            $newtemplate | Add-Member -MemberType $_.MemberType -Name $_.Name -Value $_.Value
        }

        if(-not (Internal-HasProperty -inputObject $newtemplate -propertyName 'Type')){
            Internal-AddProperty -inputObject $newtemplate -propertyName 'Type' -propertyValue 'ItemTemplate'
        }
    }
}

function TemplateAdd-SourceFile{
    [cmdletbinding()]
    param(
        [Parameter(Position=1,Mandatory=$true)]
        [ValidateNotNull()]
        [string[]]$sourceFiles,

        [Parameter(Position=2)]
        [ScriptBlock[]]$destFiles,

        [Parameter(Position=3,Mandatory=$true,ValueFromPipeline=$true)]
        [ValidateNotNull()]
        $templateInfo
    )
    process{
        if( ($destFiles -ne $null) -and ($destFiles.Count -gt 0) ){
            if($sourceFiles.Count -ne $destFiles.Count){
                throw ('Number of source files [{0}] is not equal number of dest files [{1}]',$sourceFiles.Count,$destFiles.Count)
            }
        }

        if(-not (Internal-HasProperty -inputObject $templateInfo -propertyName 'SourceFiles')){
            Internal-AddProperty -inputObject $templateInfo -propertyName 'SourceFiles' -propertyValue @()
        }

        for($i = 0;$i -lt $sourceFiles.Count;$i++){
            [ScriptBlock]$dest = $null
            if( ($destFiles -ne $null) -and ($destFiles.Count -gt 0) ){
                $dest = $destFiles[$i]
            }

            if($dest -eq $null){
                [string]$str =  '"{0}"' -f $sourceFiles[$i]
                $dest = [ScriptBlock]::Create($str)
            }

            $templateInfo.SourceFiles += New-Object -TypeName psobject -Property @{
                SourceFile = [System.IO.FileInfo]($sourceFiles[$i])
                DestFile = [ScriptBlock]$dest
            }
        }

    }
}

set-alias Add-SourceFile TemplateAdd-SourceFile

function TemplateAdd-Replacement{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        $templateInfo,

        [Parameter(Position=1,Mandatory=$true)]
        [string]$replaceKey,

        [Parameter(Position=2,Mandatory=$true)]
        [ScriptBlock]$replaceValue,

        [Parameter(Position=3)]
        [ScriptBlock]$defaultValue,

        [Parameter(Position=4)]
        [string]$rootDir,

        [Parameter(Position=5)]
        [string[]]$include = @('*'),

        [Parameter(Position=6)]
        [string[]]$exclude
    )
    process{
        # make sure it has the properties member, if not add it
        if(-not (Internal-HasProperty -inputObject $templateInfo -propertyName 'Replacements')){
            Internal-AddProperty -inputObject $templateInfo -propertyName 'Replacements' -propertyValue @()
        }
        
        $templateInfo.Replacements += New-Object -TypeName psobject -Property @{
            ReplaceKey = $replaceKey
            ReplaceValue = $replaceValue
            DefaultValue = $defaultValue
            RootDir = $rootDir
            Include = $include
            Exclude = $exclude
        }
    }
}
Set-Alias replaceitem TemplateAdd-Replacement

function TemplateAddd-ReplacementObject{
    param(
        [Parameter(Position=1,Mandatory=$true)]
        [object[][]]$replacementObject,

        [Parameter(Position=2,Mandatory=$true,ValueFromPipeline=$true)]
        $templateInfo,

        [Parameter(Position=3)]
        [string]$rootDir,

        [Parameter(Position=4)]
        [string[]]$include = @('*'),

        [Parameter(Position=5)]
        [string[]]$exclude

    )
    process{
        $global:foo = $replacementObject
        foreach($repobj in $replacementObject){
            # add a replacement for each
            if($repobj.length -lt 2){
                throw ('replacement object requires at least two items, ReplaceKey and ReplaceValue. Num elements in replacement [{0}]{1}' -f $repobj.length,(Get-PSCallStack|Out-String))
            }
            $repKey = $repobj[0]
            $repValue = $repobj[1]
            $defaultValue = [ScriptBlock]$null
            if($repobj.length -gt 2){
                $defaultValue = $repobj[2]
            }

            $addargs = @{
                TemplateInfo = $templateInfo
                ReplaceKey = $repKey
                ReplaceValue = $repValue
                DefaultValue = $defaultValue
                RootDir = $rootDir
                Include = $include
                Exclude = $exclude
            }

            TemplateAdd-Replacement @addargs
        }
    }    
}

set-alias replace TemplateAddd-ReplacementObject

function TemplateUpdate-FileName{
    [cmdletbinding()]
    param(
        [Parameter(Position=1,Mandatory=$true,ValueFromPipeline = $true)]
        $templateInfo,

        [Parameter(Position=2,Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$replaceKey,

        [Parameter(Position=3,Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [ScriptBlock]$replaceValue,

        [Parameter(Position=4)]
        [ScriptBlock]$defaultValue
    )
    process{
        if(-not (Internal-HasProperty -inputObject $templateInfo -propertyName 'UpdateFilenames')){
            Internal-AddProperty -inputObject $templateInfo -propertyName 'UpdateFilenames' -propertyValue @()
        }

        $templateInfo.UpdateFilenames += New-Object -TypeName psobject -Property @{
            ReplaceKey = $replaceKey
            ReplaceValue = $replaceValue
            DefaultValue = $defaultValue
        }
    }
}

function TemplateUpdate-FilenameObject{
    param(
        [Parameter(Position=1,Mandatory=$true)]
        [object[][]]$updateObject,

        [Parameter(Position=2,Mandatory=$true,ValueFromPipeline = $true)]
        $templateInfo
    )
    process{
        foreach($upObj in $updateObject){
            if($upObj -ne $null){
                if($upObj.length -lt 2){
                    throw ('Update object requires at least two values but found [{0}] number of values' -f $upObj.length)
                }

                $defaultValue = [ScriptBlock]$null
                if($upObj.length -ge 3){
                    $defaultValue = $upObj[2]
                }
                TemplateUpdate-FileName -templateInfo $templateInfo -replaceKey ($upObj[0]) -replaceValue ($upObj[1]) -defaultValue $defaultValue
            }
        }
    }
}
Set-Alias Update-FileName TemplateUpdate-FilenameObject

function TemplateBefore-Install{
    [cmdletbinding()]
    param(
        [Parameter(Position=1,Mandatory=$true)]
        $templateInfo,
        [Parameter(Position=2,Mandatory=$true)]
        [ScriptBlock]$beforeInstall
    )
    process{
        if(-not (Internal-HasProperty -inputObject $templateInfo -propertyName 'BeforeInstall')){
            Internal-AddProperty -inputObject $templateInfo -propertyName 'BeforeInstall' -propertyValue $beforeInstall
        }
        else{
            $templateInfo.BeforeInstall = $beforeInstall
        }
    }
}
Set-Alias beforeinstall TemplateBefore-Install

function TemplateAfter-Install{
    [cmdletbinding()]
    param(
        [Parameter(Position=1,Mandatory=$true)]
        $templateInfo,
        [Parameter(Position=2,Mandatory=$true)]
        [ScriptBlock]$afterInstall
    )
    process{
        if(-not (Internal-HasProperty -inputObject $templateInfo -propertyName 'AfterInstall')){
            Internal-AddProperty -inputObject $templateInfo -propertyName 'AfterInstall' -propertyValue $afterInstall
        }
        else{
            $templateInfo.AfterInstall = $afterInstall
        }
    }
}
Set-Alias afterinstall TemplateAfter-Install

function TemplateExclude-File{
    [cmdletbinding()]
    param(
        [Parameter(Position=1,Mandatory=$true)]
        [ValidateNotNull()]
        [string[]]$excludeFiles,

        [Parameter(Position=2,Mandatory=$true,ValueFromPipeline=$true)]
        $templateInfo
    )
    process{
        if(-not (Internal-HasProperty -inputObject $templateInfo -propertyName 'ExcludeFiles')){
            Internal-AddProperty -inputObject $templateInfo -propertyName 'ExcludeFiles' -propertyValue @()
        }

        $templateInfo.ExcludeFiles += $excludeFiles
    }
}
Set-Alias Exclude-File TemplateExclude-File

function TemplateExclude-Folder{
    [cmdletbinding()]
    param(
        [Parameter(Position=1,Mandatory=$true)]
        [ValidateNotNull()]
        [string[]]$excludeFolder,

        [Parameter(Position=2,Mandatory=$true,ValueFromPipeline=$true)]
        $templateInfo
    )
    process{
        if(-not (Internal-HasProperty -inputObject $templateInfo -propertyName 'ExcludeFolder')){
            Internal-AddProperty -inputObject $templateInfo -propertyName 'ExcludeFolder' -propertyValue @()
        }

        $templateInfo.ExcludeFolder += $excludeFolder
    }
}
Set-Alias Exclude-Folder TemplateExclude-Folder

function Clear-AllTemplates{
    [cmdletbinding()]
    param()
    process{
        $global:pecanwafflesettings.Templates.Clear()
    }
}

function TemplateSet-TemplateInfo{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [ValidateNotNull()]
        $templateInfo,

        [Parameter(Position=1)]
        [System.IO.DirectoryInfo]$templateRoot
    )
    process{
        if(-not (Internal-HasProperty -inputObject $templateInfo -propertyName 'TemplatePath')){
            Internal-AddProperty -inputObject $templateInfo -propertyName 'TemplatePath' -propertyValue @()

            if($templateRoot -eq $null){
                # root is the folder from the calling script
                $templateRoot = ((Get-Item ($MyInvocation.PSCommandPath)).Directory.FullName)
            }

            $templateInfo.TemplatePath = $templateRoot
        }

        $global:pecanwafflesettings.Templates += $templateInfo        
    }
}
Set-Alias Set-TemplateInfo TemplateSet-TemplateInfo

function InternalGet-EvaluatedProperty{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [ScriptBlock]$expression,

        [Parameter(Position=1,Mandatory=$true)]
        [hashtable]$properties,

        [Parameter(Position=2)]
        [hashtable]$extraProperties
    )
    process{
        [hashtable]$allProps += $properties
        if($extraProperties -ne $null){
            $allProps += $extraProperties
        }
        $scriptToExec = [ScriptBlock]::Create({$fargs=$args; foreach($f in $fargs.Keys){ New-Variable -Name $f -Value $fargs.$f };}.ToString() + $expression.ToString())
        $value = & ($scriptToExec) $allProps

        # return the value
        $value
    }
}

function InternalGet-ReplacementValue{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [ValidateNotNull()]
        $template,

        [Parameter(Position=1,Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$replaceKey,

        [Parameter(Position=2,Mandatory=$true)]
        [ValidateNotNull()]
        [hashtable]$evaluatedProperties
    )
    process{
        $replacement = ($template.Replacements| Where-Object {$_.ReplaceKey -eq $replaceKey} | Select-Object -First 1)
        if($replacement -eq $null){
            throw ('Did not find replacement with key [{0}]' -f $replaceKey)
        }

        $value = InternalGet-EvaluatedProperty -expression $replacement.ReplaceValue -properties $evaluatedProperties

        if( ($value -eq $null) -or
            ($value -is [string] -and ([string]::IsNullOrWhiteSpace($value) ) ) ) {

            if( ($replacement -ne $null) -and ($replacement.DefaultValue -ne $null)){
                $value = InternalGet-EvaluatedProperty -expression $replacement.DefaultValue -properties $evaluatedProperties
            }
        }

        $value
    }
}

function Add-Project{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [string]$templateName,

        [Parameter(Position=1)]
        [System.IO.DirectoryInfo]$destPath = (get-item $pwd),

        [Parameter(Position=2)]
        [string]$projectName = 'MyNewProject',

        [Parameter(Position=3)]
        [switch]$noNewFolder
    )
    process{
        # find the project template with the given name
        $template = ($Global:pecanwafflesettings.Templates|Where-Object {$_.Type -eq 'ProjectTemplate' -and $_.Name -eq $templateName}|Select-Object -First 1)

        if(-not [System.IO.Path]::IsPathRooted($destPath)){
            $destPath = (Join-Path $pwd $destPath)
        }

        if($template -eq $null){
            throw ('Did not find a project template with the name [{0}]' -f $templateName)
        }

        if(-not $noNewFolder){
            $destPath = (Join-Path $destPath.FullName $projectName)
        }

        Add-Template -template $template -destPath $destPath -properties @{'ProjectName'=$projectName}
    }
}

function Add-Item{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [string]$templateName,

        [Parameter(Position=1)]
        [System.IO.DirectoryInfo]$destPath,

        [Parameter(Position=2)]
        [string]$itemName,

        [Parameter(Position=3)]
        [string]$destFilename
    )
    process{
        # find the project template with the given name
        $template = ($Global:pecanwafflesettings.Templates|Where-Object {$_.Type -eq 'ItemTemplate' -and $_.Name -eq $templateName}|Select-Object -First 1)

        if(-not [System.IO.Path]::IsPathRooted($destPath)){
            $destPath = (Join-Path $pwd $destPath)
        }

        if($template -eq $null){
            throw ('Did not find an item template with the name [{0}]' -f $templateName)
        }

        $props = @{'ItemName'=$itemName;'DestFileName'=$destFilename}
        if(-not ([string]::IsNullOrWhiteSpace($destFilename))){
            $props['DestFileName']=$destFilename
        }
        Add-Template -template $template -destPath $destPath -properties $props
    }
}

function Add-Template{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [object]$template,

        [Parameter(Position=1)]
        [System.IO.DirectoryInfo]$destPath,

        [Parameter(Position=2)]
        [hashtable]$properties
    )
    process{
        [System.IO.DirectoryInfo]$tempWorkDir = InternalGet-NewTempDir
        [string]$sourcePath = $template.TemplatePath
        
        try{
            # eval properties here
            $evaluatedProps = @{}
            if($properties -ne $null){
                foreach($key in $properties.Keys){
                    $evaluatedProps[$key]=$properties[$key]
                }
            }

            $evaluatedProps['templateWorkingDir'] = $tempWorkDir.FullName
            # add all the properties of $template into evaluatedProps
            foreach($name in $template.psobject.Properties.Name){
                $evaluatedProps[$name]=($template.$name)
            }
            
            if($template.Replacements -ne $null){
                foreach($rep in $template.Replacements){
                    $evaluatedProps[$rep.ReplaceKey] = InternalGet-ReplacementValue -template $template -replaceKey $rep.ReplaceKey -evaluatedProperties $evaluatedProps
                }
            }

            if( ($template.SourceFiles -eq $null) -or ($template.SourceFiles.Count -le 0)){
                # copy all of the files to the temp directory
                'Copying template files from [{0}] to [{1}]' -f $template.TemplatePath,$tempWorkDir.FullName | Write-Verbose
                Copy-Item -Path $sourcePath\* -Destination $tempWorkDir.FullName -Recurse -Include * -Exclude ($template.ExcludeFiles)
            }
            else{
                foreach($sf in  $template.SourceFiles){
                    $source = $sf.SourceFile;
                    
                    [System.IO.FileInfo]$sourceFile = (Join-Path $sourcePath $source)
                    [hashtable]$extraProps = @{
                        'ThisItemName' = $sourceFile.BaseName
                        'ThisItemFileName' = $sourceFile.Name
                    }

                    $dest = (InternalGet-EvaluatedProperty -expression ($sf.DestFile) -properties $evaluatedProps -extraProperties $extraProps)
                    
                    if([string]::IsNullOrWhiteSpace($dest)){
                        throw ('Dest is null or empty for source [{0}]' -f $source)
                    }

                    Copy-Item -Path $sourceFile.FullName -Destination ((Join-Path $tempWorkDir.FullName $dest))
                }
            }

            # remove excluded files (in some cases excluded files can still be copied to temp
            #   for example if you specify sourcefile/destfile and include a file that should be excluded
            if($template.ExcludeFiles -ne $null){
                $files = (Get-ChildItem $tempWorkDir.FullName ($template.ExcludeFiles -join ';') -Recurse -File)
                if( ($files -ne $null) -and ($files.Length -gt 0) ){
                    Remove-Item $files.FullName -ErrorAction SilentlyContinue
                }
            }

            # remove directories in the exclude list
            if($template.ExcludeFolder -ne $null){
                Get-ChildItem -Path $tempWorkDir.FullName -Include $template.ExcludeFolder -Recurse -Directory | Remove-Item -Recurse -ErrorAction SilentlyContinue
            }

            # replace file names
            if($template.UpdateFilenames -ne $null){
                foreach($current in $template.UpdateFilenames){
                    foreach($file in ([System.IO.FileInfo[]](Get-ChildItem $tempWorkDir.FullName ('*{0}*' -f $current.ReplaceKey) -Recurse)) ){
                        $file = [System.IO.FileInfo]$file
                        $repvalue = InternalGet-EvaluatedProperty -expression $current.ReplaceValue -properties $evaluatedProps

                        if([string]::IsNullOrWhiteSpace($repvalue) -and ($current.DefaultValue -ne $null)){
                            $repvalue = InternalGet-EvaluatedProperty -expression $current.DefaultValue -properties $evaluatedProps
                        }

                        $newname = $file.Name.Replace($current.ReplaceKey, $repvalue)
                        [System.IO.FileInfo]$newpath = (Join-Path ($file.Directory.FullName) $newname)
                        Move-Item $file.FullName $newpath.FullName
                    }
                }
            }

            if($template.BeforeInstall -ne $null){
                InternalGet-EvaluatedProperty -expression $template.BeforeInstall -properties $evaluatedProps
            }

            # replace content in files
            Import-FileReplacer | Out-Null

            foreach($r in $template.Replacements){
                $rvalue = InternalGet-ReplacementValue -template $template -replaceKey $r.ReplaceKey -evaluatedProperties $evaluatedProps

                $evaluatedProps[$r.ReplaceKey]=$rvalue

                $replacements = @{
                    $r.ReplaceKey = $rvalue
                }

                $replaceArgs = @{
                    folder = $tempWorkDir.FullName
                    replacements = $replacements
                    include = '*'
                    exclude = $null
                }

                if($r.Include -ne $null){
                    $replaceArgs.include = ($r.include -join ';')
                }
                if($r.Exclude -ne $null){
                    $replaceArgs.exclude = ($r.Exclude -join ';')
                }

                Replace-TextInFolder @replaceArgs
            }

            # copy the final result to the destination
            if(-not (Test-Path $destPath.FullName)){
                New-Item -Path $destPath.FullName -ItemType Directory
            }
            [string]$tpath = $tempWorkDir.FullName
            
            Copy-Item $tpath\* -Destination $destPath.FullName -Recurse -Include *

            if($template.AfterInstall -ne $null){
                InternalGet-EvaluatedProperty -expression $template.AfterInstall -properties $evaluatedProps
            }
        }
        finally{
            # delete the temp dir and ignore any errors
            if(Test-Path $tempWorkDir.FullName){
                Remove-Item $tempWorkDir.FullName -Recurse -ErrorAction SilentlyContinue
            }
        }
    }
}

# Helpers for externals

<#
.SYNOPSIS
    This will download and import nuget-powershell (https://github.com/ligershark/nuget-powershell),
    which is a PowerShell utility that can be used to easily download nuget packages.

    If nuget-powershell is already loaded then the download/import will be skipped.

.PARAMETER nugetPsMinModVersion
    The minimum version to import
#>
function Import-NuGetPowershell{
    [cmdletbinding()]
    param(
        $nugetPsMinModVersion = '0.2.1.1'
    )
    process{
        # see if nuget-powershell is available and load if not
        $nugetpsloaded = $false
        if((get-command Get-NuGetPackage -ErrorAction SilentlyContinue)){
            # check the module to ensure we have the correct version

            $currentversion = (Get-Module -Name nuget-powershell).Version
            if( ($currentversion -ne $null) -and ($currentversion.CompareTo([version]::Parse($nugetPsMinModVersion)) -ge 0 )){
                $nugetpsloaded = $true
            }
        }

        if(!$nugetpsloaded){
            (new-object Net.WebClient).DownloadString("https://raw.githubusercontent.com/ligershark/nuget-powershell/master/get-nugetps.ps1") | iex
        }

        # check to see that it was loaded
        if((get-command Get-NuGetPackage -ErrorAction SilentlyContinue)){
            $nugetpsloaded = $true
        }

        if(-not $nugetpsloaded){
            throw ('Unable to load nuget-powershell, unknown error')
        }
    }
}

<#
.SYNOPSIS
    This will download and import the given version of file-replacer (https://github.com/ligershark/template-builder/blob/master/file-replacer.psm1),
    which can be used to replace text in files under a given folder.

    If file-replacer is already loaded then the download/import will be skipped.

.PARAMETER fileReplacerVersion
    The version to import.
#>
function Import-FileReplacer{
    [cmdletbinding()]
    param(
        [string]$fileReplacerVersion = '0.4.0-beta'
    )
    process{
        $fileReplacerLoaded = $false
        # Replace-TextInFolder
        if(get-command Replace-TextInFolder -ErrorAction SilentlyContinue){
            $fileReplacerLoaded = $true
        }

        # download/import file-replacer
        if(-not $fileReplacerLoaded){
            'Importing file-replacer version [{0}]' -f $fileReplacerVersion | Write-Verbose
            Import-NuGetPowershell | Out-Null
            $pkgpath = (Get-NuGetPackage 'file-replacer' -version $fileReplacerVersion -binpath)
            Import-Module (Join-Path $pkgpath 'file-replacer.psm1') -DisableNameChecking -Global | Out-Null
        }
    }
}

if($global:pecanwafflesettings.EnableAddLocalSourceOnLoad -eq $true){
    Add-TemplateSource -path (InternalGet-ScriptDirectory)
}
# TODO: Update this later
Export-ModuleMember -function * -Alias *

