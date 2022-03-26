param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory=$true)]
    [string]$ConvertedProjectRoot)

# Copy the project to the target directory, if it's not an in-place conversion.

if ($ProjectRoot -ine $ConvertedProjectRoot)
{
    Write-Host "Copying files from $ProjectRoot to $ConvertedProjectRoot..."

    foreach ($file in (Get-ChildItem $ProjectRoot -Recurse -File))
    {
        [System.IO.FileSystemInfo]$file = $file
        $targetPath = $file.FullName.Replace($ProjectRoot, $ConvertedProjectRoot)
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($targetPath)) | Out-Null
        Copy-Item $file.FullName $targetPath
    }
}

# Modify solution files to remove the ARM configuration.

Write-Host "Updating solution files to support WinAppSDK..."

function Get-RelativePath([string]$Path, [string]$RelativeTo)
{
    try
    {
        Push-Location $RelativeTo
        $relativePath = Resolve-path -Relative $Path
    }
    finally
    {
        Pop-Location
    }

    return $relativePath
}

[System.Collections.Generic.Dictionary[string, string]]$projectToPackagesDirectoryDictionary = @{}

foreach ($solutionFile in ((Get-ChildItem $ConvertedProjectRoot -Recurse -File -Filter "*.sln")))
{
    [System.IO.FileSystemInfo]$solutionFile = $solutionFile
    [string]$fileContents = [System.IO.File]::ReadAllText($solutionFile.FullName)
    $originalFileContents = $fileContents
    
    $fileContents = $fileContents -ireplace "\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\.\w+\|ARM\.\w+(?:\.\w+)?\s*=\s*\w+\|ARM[\s\n\r]*", ""
    $fileContents = $fileContents -ireplace "\w+?\|ARM = \w+?\|ARM[\s\n\r]*", ""
    $fileContents = $fileContents -replace "ARM64", "arm64"
    
    if ($fileContents -ne $originalFileContents)
    {
        [System.IO.File]::WriteAllText($solutionFile.FullName, $fileContents, [System.Text.Encoding]::UTF8)
    }

    # Any projects in this solution file will have their packages directory be in the folder containing this solution file.
    $solutionDirectory = [System.IO.Path]::GetDirectoryName($solutionFile.FullName)
    $packagesDirectory = [System.IO.Path]::Combine($solutionDirectory, "packages")

    if (-not [System.IO.Directory]::Exists($packagesDirectory))
    {
        New-Item $packagesDirectory -ItemType Directory | Out-Null
    }

    $guidRegex = "\{[0-9a-f-A-F]{8}-[0-9a-f-A-F]{4}-[0-9a-f-A-F]{4}-[0-9a-f-A-F]{4}-[0-9a-f-A-F]{12}\}"
    foreach ($projectReferenceMatch in ([regex]"Project\(`"$guidRegex`"\)\s*=\s*`"[^`"]*?`",\s*`"([^`"]*)`",\s*`"$guidRegex`"").Matches($fileContents))
    {
        [System.Text.RegularExpressions.Match]$projectReferenceMatch = $projectReferenceMatch
        $projectPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($solutionDirectory, $projectReferenceMatch.Groups[1].Value))

        if ([System.IO.File]::Exists($projectPath))
        {
            if (-not $projectToPackagesDirectoryDictionary.ContainsKey($projectPath))
            {
                $projectToPackagesDirectoryDictionary.Add($projectPath, (Get-RelativePath $packagesDirectory ([System.IO.Path]::GetDirectoryName($projectPath))))
            }
        }
    }
}

# A project file only needs updates if
#   a) it contains references to Microsoft.UI.Xaml or Microsoft.Toolkit.Win32.UI.XamlApplication; or
#   b) it contains references to source files that contain references to Windows.UI.Xaml.
# If either of these are true, we'll add the project to the list of project files needing updates
# and add its source files to the list of source files to be updated.

[System.Collections.Generic.List[string]]$projectFilesNeedingUpdates = @()
[System.Collections.Generic.List[string]]$sourceFilesNeedingUpdates = @()
[System.Collections.Generic.List[string]]$xamlFilesNeedingUpdates = @()

foreach ($projectFile in $projectToPackagesDirectoryDictionary.Keys)
{
    [System.Xml.XmlDocument]$fileAsXml = [xml]([System.IO.File]::ReadAllText($projectFile))
    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($fileAsXml.NameTable)
    $namespaceManager.AddNamespace("x", $fileAsXml.Project.NamespaceURI)

    $microsoftUiXamlImports = $fileAsXml.DocumentElement.SelectNodes("//x:Import[contains(@Project, 'Microsoft.UI.Xaml')]", $namespaceManager)
    $xamlApplicationImports = $fileAsXml.DocumentElement.SelectNodes("//x:Import[contains(@Project, 'Microsoft.Toolkit.Win32.UI.XamlApplication')]", $namespaceManager)
    $clIncludes = $fileAsXml.DocumentElement.SelectNodes("//x:ItemGroup/x:ClInclude", $namespaceManager)
    $clCompiles = $fileAsXml.DocumentElement.SelectNodes("//x:ItemGroup/x:ClCompile", $namespaceManager)
    $midls = $fileAsXml.DocumentElement.SelectNodes("//x:ItemGroup/x:Midl", $namespaceManager)
    $compiles = $fileAsXml.DocumentElement.SelectNodes("//x:ItemGroup/x:Compile", $namespaceManager)

    $projectFileNeedsUpdates = $false

    [System.Collections.Generic.List[string]]$sourceFiles = @()

    foreach ($sourceFile in $clIncludes + $clCompiles + $midls + $compiles)
    {
        $sourceFilePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($projectFile), $sourceFile.Include))

        if ([System.IO.File]::Exists($sourceFilePath))
        {
            $sourceFiles.Add($sourceFilePath)
        }
    }

    if ($microsoftUiXamlImports.Count -gt 0 -or $xamlApplicationImports.Count -gt 0)
    {
        $projectFileNeedsUpdates = $true
    }
    else
    {
        foreach ($sourceFile in $sourceFiles)
        {
            [string]$sourceFileContents = [System.IO.File]::ReadAllText($sourceFile)

            if ($sourceFileContents.Contains("Windows.UI.Xaml") -or $sourceFileContents.Contains("Windows::UI::Xaml"))
            {
                $projectFileNeedsUpdates = $true
                break
            }
        }
    }

    if ($projectFileNeedsUpdates)
    {
        $projectFilesNeedingUpdates.Add($projectFile)

        foreach ($sourceFile in $sourceFiles)
        {
            if (-not $sourceFilesNeedingUpdates.Contains($sourceFile))
            {
                $sourceFilesNeedingUpdates.Add($sourceFile)
            }
        }

        $pages = $fileAsXml.DocumentElement.SelectNodes("//x:ItemGroup/x:Page", $namespaceManager)
        $applicationDefinitions = $fileAsXml.DocumentElement.SelectNodes("//x:ItemGroup/x:ApplicationDefinition", $namespaceManager)

        foreach ($xamlFile in $pages + $applicationDefinitions)
        {
            $xamlFilePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($projectFile), $xamlFile.Include))

            if ([System.IO.File]::Exists($xamlFilePath))
            {
                $xamlFilesNeedingUpdates.Add($xamlFilePath)
            }
        }
    }
}

. ".\XmlHelperFunctions.ps1"

[System.Collections.Generic.List[string]]$packagesConfigFilesNeedingUpdate = @()
[System.Collections.Generic.List[pscustomobject]]$appxManifestsNeedingUpdate = @()

Write-Host "Updating project files to support WinAppSDK..."

foreach ($file in $projectFilesNeedingUpdates)
{
    Write-Host "    Updating $file..."

    [string]$fileContents = [System.IO.File]::ReadAllText($file)

    [System.Xml.XmlDocument]$fileAsXml = [xml]($fileContents.Replace("ARM64", "arm64"))
    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($fileAsXml.NameTable)
    $namespaceManager.AddNamespace("x", $fileAsXml.Project.NamespaceURI)

    # Remove ARM project configurations, which are not supported by WinAppSDK.

    RemoveItem $fileAsXml $namespaceManager "ProjectConfiguration" "Debug|ARM"
    RemoveItem $fileAsXml $namespaceManager "ProjectConfiguration" "Release|ARM"

    # Save off the windows target platform versions.

    [System.Xml.XmlElement]$windowsTargetPlatformVersionProperty = $fileAsXml.DocumentElement.SelectSingleNode("//x:PropertyGroup/x:WindowsTargetPlatformVersion[last()]", $namespaceManager)
    
    if ($windowsTargetPlatformVersionProperty -and $windowsTargetPlatformVersionProperty.InnerText -ne "10.0")
    {
        $windowsTargetPlatformVersion = $windowsTargetPlatformVersionProperty.InnerText
    }
    else
    {
        # We'll default to 10.0.22000.0
        $windowsTargetPlatformVersion = "10.0.22000.0"
    }

    [System.Xml.XmlElement]$windowsTargetPlatformMinVersionProperty = $fileAsXml.DocumentElement.SelectSingleNode("//x:PropertyGroup/x:WindowsTargetPlatformMinVersion[last()]", $namespaceManager)
    
    if ($windowsTargetPlatformMinVersionProperty)
    {
        $windowsTargetPlatformMinVersion = $windowsTargetPlatformMinVersionProperty.InnerText
    }
    else
    {
        # We'll default to 10.0.17134.0
        $windowsTargetPlatformMinVersion = "10.0.17134.0"
    }

    # Now we'll schedule an update to the AppX manifest including those versions.

    foreach ($appxManifestElement in $fileAsXml.DocumentElement.SelectNodes("//x:ItemGroup/x:AppxManifest", $namespaceManager))
    {
        [System.Xml.XmlElement]$appxManifestElement = $appxManifestElement

        # Save off this AppX manifest for more thorough updating later as well.
        $appxManifestsNeedingUpdate.Add([pscustomobject]@{
            Path = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($file), $appxManifestElement.GetAttribute("Include"));
            Version = $windowsTargetPlatformVersion;
            MinVersion = $windowsTargetPlatformMinVersion
        })
    }

    # Change
    #   <WindowsTargetPlatformVersion>10.0.22000.0</WindowsTargetPlatformVersion>
    # to
    #   <WindowsTargetPlatformVersion>10.0</WindowsTargetPlatformVersion>

    CreateOrUpdateProperty $fileAsXml $namespaceManager "WindowsTargetPlatformVersion" "10.0"

    # Add additional NuGet includes before and after the CppWinRT props/targets files and remove Microsoft.UI.Xaml targets files.

    $packagesPath = $projectToPackagesDirectoryDictionary[$file]

    if (-not $packagesPath)
    {
        $packagesPath = "packages"
    }

    $cppWinRTPropsFilename = "Microsoft.Windows.CppWinRT.props"
    
    CreateNugetImport $fileAsXml $namespaceManager "$packagesPath\Microsoft.Windows.SDK.BuildTools.10.0.22000.194\build\Microsoft.Windows.SDK.BuildTools.props" $cppWinRTPropsFilename
    CreateNugetImport $fileAsXml $namespaceManager "$packagesPath\Microsoft.WindowsAppSDK.1.1.0-20220302.0-CI-experimental\build\native\Microsoft.WindowsAppSDK.props" $cppWinRTPropsFilename

    $cppWinRTTargetsFilename = "Microsoft.Windows.CppWinRT.targets"

    CreateNugetImport $fileAsXml $namespaceManager "$packagesPath\Microsoft.Windows.ImplementationLibrary.1.0.211019.2\build\native\Microsoft.Windows.ImplementationLibrary.targets" $cppWinRTTargetsFilename
    CreateNugetImport $fileAsXml $namespaceManager "$packagesPath\Microsoft.WindowsAppSDK.1.1.0-20220302.0-CI-experimental\build\native\Microsoft.WindowsAppSDK.targets" $cppWinRTTargetsFilename
    CreateNugetImport $fileAsXml $namespaceManager "$packagesPath\Microsoft.Windows.SDK.BuildTools.10.0.22000.194\build\Microsoft.Windows.SDK.BuildTools.targets" $cppWinRTTargetsFilename

    RemoveNugetImport $fileAsXml $namespaceManager "Microsoft.Toolkit.Win32.UI.XamlApplication.props"
    RemoveNugetImport $fileAsXml $namespaceManager "Microsoft.Toolkit.Win32.UI.XamlApplication.targets"
    RemoveNugetImport $fileAsXml $namespaceManager "Microsoft.UI.Xaml.targets"

    # Add this 

    $packagesConfigFilesNeedingUpdate.Add([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($file), "packages.config"))

    # Add
    #   <AppxPackage>true</AppxPackage>
    #   <EnablePreviewMsixTooling>true</EnablePreviewMsixTooling>
    #   <TargetName>$(RootNamespace)</TargetName>
    #   <UseWinUI>true</UseWinUI>
    
    CreateOrUpdateProperty $fileAsXml $namespaceManager "EnablePreviewMsixTooling" "true"
    CreateOrUpdateProperty $fileAsXml $namespaceManager "TargetName" "`$(RootNamespace)"
    CreateOrUpdateProperty $fileAsXml $namespaceManager "UseWinUI" "true"

    # Add
    #   <AppxPackage>true</AppxPackage>
    # if this project has an AppX manifest.

    $appxManifestPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($file), "Package.appxmanifest")

    if ([System.IO.File]::Exists($appxManifestPath))
    {
        CreateOrUpdateProperty $fileAsXml $namespaceManager "AppxPackage" "true"
    }

    # Add
    #   <DesktopCompatible>true</DesktopCompatible>
    # to the first property group after the include of Microsoft.Cpp.Default.props.

    [System.Xml.XmlElement]$desktopCompatibleProperty = $fileAsXml.DocumentElement.SelectSingleNode("//x:PropertyGroup/x:DesktopCompatible[last()]", $namespaceManager)

    if (-not $desktopCompatibleProperty)
    {
        $desktopCompatibleProperty = $fileAsXml.CreateElement([string]::Empty, "DesktopCompatible", $fileAsXml.DocumentElement.NamespaceURI)

        [System.Xml.XmlElement]$defaultCppPropsImport = $fileAsXml.DocumentElement.SelectSingleNode("//x:Import[contains(@Project, 'Microsoft.Cpp.Default.props')]", $namespaceManager)

        [System.Xml.XmlElement]$nextPropertyGroupElement = $null
        [System.Xml.XmlElement]$currentElement = $defaultCppPropsImport

        while ($currentElement)
        {
            if ($currentElement.Name -eq "PropertyGroup")
            {
                $nextPropertyGroupElement = $currentElement
                break
            }
            
            $currentElement = $currentElement.NextSibling
        }

        # If there was no property group after this element, we'll create a new one at the end.
        if (-not $nextPropertyGroupElement)
        {
            $nextPropertyGroupElement = $fileAsXml.CreateElement([string]::Empty, "PropertyGroup", $fileAsXml.DocumentElement.NamespaceURI)
            $fileAsXml.DocumentElement.AppendChild($nextPropertyGroupElement) | Out-Null
        }

        $nextPropertyGroupElement.AppendChild($desktopCompatibleProperty) | Out-Null
    }
    
    $desktopCompatibleProperty.RemoveAll()
    $desktopCompatibleProperty.AppendChild($fileAsXml.CreateTextNode("true")) | Out-Null

    # Change
    #   <AppContainerApplication>true</AppContainerApplication>
    # to
    #   <AppContainerApplication>false</AppContainerApplication>

    CreateOrUpdateProperty $fileAsXml $namespaceManager "AppContainerApplication" "false"

    # Remove
    #   <CppWinRTGenerateWindowsMetadata>true</CppWinRTGenerateWindowsMetadata>
    #   <GenerateWindowsMetadata>true</GenerateWindowsMetadata>

    RemoveProperty $fileAsXml $namespaceManager "CppWinRTGenerateWindowsMetadata"
    RemoveItemDefinitionGroupProperty $fileAsXml $namespaceManager "Link" "GenerateWindowsMetadata"

    # Remove
    #   /DWINRT_NO_MAKE_DETECTION
    #   WIN32_LEAN_AND_MEAN
    #   WINRT_LEAN_AND_MEAN

    RemoveFromItemDefinitionGroupProperty $fileAsXml $namespaceManager "ClCompile" "AdditionalOptions" "/DWINRT_NO_MAKE_DETECTION"
    RemoveFromItemDefinitionGroupProperty $fileAsXml $namespaceManager "ClCompile" "PreprocessorDefinitions" "WIN32_LEAN_AND_MEAN"
    RemoveFromItemDefinitionGroupProperty $fileAsXml $namespaceManager "ClCompile" "PreprocessorDefinitions" "WINRT_LEAN_AND_MEAN"

    # Add the app.manifest file.

    $appManifestPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($file), "app.manifest")

    if (-not [System.IO.File]::Exists($appManifestPath))
    {
        $appManifestContents = @"
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="BlankApp.app"/>

  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <!-- The combination of below two tags have the following effect:
           1) Per-Monitor for >= Windows 10 Anniversary Update
           2) System < Windows 10 Anniversary Update
      -->
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/PM</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2, PerMonitor</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
"@

        [System.IO.File]::WriteAllText($appManifestPath, $appManifestContents, [System.Text.Encoding]::UTF8)
    }
    
    # Add an include for
    #   <ItemGroup>
    #     <Manifest Include="app.manifest" />
    #   </ItemGroup>
    
    CreateItem $fileAsXml $namespaceManager "Manifest" "app.manifest"

    # Add an include for
    #   <ItemGroup>
    #     <ProjectCapability Include="Msix" Condition="'$(DisableMsixProjectCapabilityAddedByProject)'!='true' and '$(EnablePreviewMsixTooling)'=='true'" />
    #   </ItemGroup>
    
    CreateItem $fileAsXml $namespaceManager "ProjectCapability" "Msix" "'`$(DisableMsixProjectCapabilityAddedByProject)'!='true' and '`$(EnablePreviewMsixTooling)'=='true'"

    $fileAsXml.Save($file)
}

# Modify AppX manifest files to match the WinAppSDK expectations.

Write-Host "Updating AppX manifest files to support WinAppSDK..."

foreach ($appxManifest in $appxManifestsNeedingUpdate)
{
    Write-Host "    Updating $appxManifest"

    [System.Xml.XmlDocument]$appxManifestAsXml = [xml]([System.IO.File]::ReadAllText($appxManifest.Path))
    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($appxManifestAsXml.NameTable)
    $namespaceManager.AddNamespace("x", $appxManifestAsXml.Package.NamespaceURI)
    $namespaceManager.AddNamespace("mp", "http://schemas.microsoft.com/appx/2014/phone/manifest")
    $namespaceManager.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
    $namespaceManager.AddNamespace("rescap", "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities")

    # Add "rescap" to the set of ignorable namespaces.

    $appxManifestAsXml.Package.IgnorableNamespaces = "uap mp rescap"

    # Get the Windows.Universal TargetDeviceFamily entry and update its versions.

    [System.Xml.XmlElement]$universalTargetDeviceFamily = $appxManifestAsXml.DocumentElement.SelectSingleNode("//x:Dependencies/x:TargetDeviceFamily[@Name='Windows.Universal']", $namespaceManager)
    $universalTargetDeviceFamily.SetAttribute("MinVersion", $appxManifest.MinVersion)
    $universalTargetDeviceFamily.SetAttribute("MaxVersionTested", $appxManifest.Version)

    # Get the Windows.Desktop TargetDeviceFamily and update its versions as well, if it exists.
    # If it doesn't, create it and add it next to the Windows.Universal TargetDeviceFamily.

    [System.Xml.XmlElement]$desktopTargetDeviceFamily = $appxManifestAsXml.DocumentElement.SelectSingleNode("//x:Dependencies/x:TargetDeviceFamily[@Name='Windows.Desktop']", $namespaceManager)

    if (-not $desktopTargetDeviceFamily)
    {
        $desktopTargetDeviceFamily = $appxManifestAsXml.CreateElement([string]::Empty, "TargetDeviceFamily", $appxManifestAsXml.DocumentElement.NamespaceURI)
        $desktopTargetDeviceFamily.SetAttribute("Name", "Windows.Desktop")
        $universalTargetDeviceFamily.ParentNode.InsertAfter($desktopTargetDeviceFamily, $universalTargetDeviceFamily) | Out-Null
    }

    $desktopTargetDeviceFamily.SetAttribute("MinVersion", $appxManifest.MinVersion)
    $desktopTargetDeviceFamily.SetAttribute("MaxVersionTested", $appxManifest.Version)

    # Update the entry point to match the one expected for the WinAppSDK.

    [System.Xml.XmlElement]$applicationWithEntryPoint = $appxManifestAsXml.DocumentElement.SelectSingleNode("//x:Applications/x:Application[contains(@EntryPoint, '.App')]", $namespaceManager)

    if ($applicationWithEntryPoint)
    {
        $applicationWithEntryPoint.SetAttribute("EntryPoint", "`$targetentrypoint`$")
    }

    # Add the runFullTrust capability, if one doesn't already exist.

    if (-not $appxManifestAsXml.DocumentElement.SelectSingleNode("//x:Capabilities/rescap:Capability[@Name='runFullTrust']", $namespaceManager))
    {
        [System.Xml.XmlElement]$capabilities = $appxManifestAsXml.DocumentElement.SelectSingleNode("//x:Capabilities", $namespaceManager)

        [System.Xml.XmlElement]$runFullTrustCapability = $appxManifestAsXml.CreateElement("rescap", "Capability", "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities")
        $runFullTrustCapability.SetAttribute("Name", "runFullTrust")

        $capabilities.AppendChild($runFullTrustCapability) | Out-Null
    }

    $appxManifestAsXml.Save($appxManifest.Path)
}

# Modify packages.config files to have the new NuGet packages required.

Write-Host "Updating packages.config files to support WinAppSDK..."

foreach ($packagesConfigFile in $packagesConfigFilesNeedingUpdate)
{
    Write-Host "    Updating $packagesConfigFile..."

    # If the file doesn't exist at all, create it.
    if (-not [System.IO.File]::Exists($packagesConfigFile))
    {
        $packagesConfigFileContents = @"
<?xml version="1.0" encoding="utf-8"?>
<packages>
  <package id="Microsoft.Windows.ImplementationLibrary" version="1.0.211019.2" targetFramework="native" />
  <package id="Microsoft.Windows.SDK.BuildTools" version="10.0.22000.194" targetFramework="native" />
  <package id="Microsoft.WindowsAppSDK" version="1.1.0-20220302.0-CI-experimental" targetFramework="native" />
</packages> 
"@

        [System.IO.File]::WriteAllText($packagesConfigFile, $packagesConfigFileContents, [System.Text.Encoding]::UTF8)
    }
    else
    {
        # If it does exist, add the new entries and remove references to Microsoft.UI.Xaml.
        $packagesConfigXml = [xml]([System.IO.File]::ReadAllText($packagesConfigFile))

        [System.Xml.XmlElement]$wilPackage = $packagesConfigXml.DocumentElement.SelectSingleNode("//packages/package[@id='Microsoft.Windows.ImplementationLibrary']")

        if (-not $wilPackage)
        {
            $wilPackage = $packagesConfigXml.CreateElement("package")
            $wilPackage.SetAttribute("id", "Microsoft.Windows.ImplementationLibrary") | Out-Null
            $packagesConfigXml.DocumentElement.AppendChild($wilPackage) | Out-Null
        }

        $wilPackage.SetAttribute("version", "1.0.211019.2")
        $wilPackage.SetAttribute("targetFramework", "native")

        [System.Xml.XmlElement]$buildToolsPackage = $packagesConfigXml.DocumentElement.SelectSingleNode("//packages/package[@id='Microsoft.Windows.SDK.BuildTools']")

        if (-not $buildToolsPackage)
        {
            $buildToolsPackage = $packagesConfigXml.CreateElement("package")
            $buildToolsPackage.SetAttribute("id", "Microsoft.Windows.SDK.BuildTools")
            $packagesConfigXml.DocumentElement.AppendChild($buildToolsPackage) | Out-Null
        }

        $buildToolsPackage.SetAttribute("version", "10.0.22000.194")
        $buildToolsPackage.SetAttribute("targetFramework", "native")

        [System.Xml.XmlElement]$winAppSdkPackage = $packagesConfigXml.DocumentElement.SelectSingleNode("//packages/package[@id='Microsoft.WindowsAppSDK']")

        if (-not $winAppSdkPackage)
        {
            $winAppSdkPackage = $packagesConfigXml.CreateElement("package")
            $winAppSdkPackage.SetAttribute("id", "Microsoft.WindowsAppSDK")
            $packagesConfigXml.DocumentElement.AppendChild($winAppSdkPackage) | Out-Null
        }

        $winAppSdkPackage.SetAttribute("version", "1.1.0-20220302.0-CI-experimental")
        $winAppSdkPackage.SetAttribute("targetFramework", "native")

        [System.Xml.XmlElement]$muxPackage = $packagesConfigXml.DocumentElement.SelectSingleNode("//packages/package[@id='Microsoft.UI.Xaml']")

        if ($muxPackage)
        {
            $muxPackage.ParentNode.RemoveChild($muxPackage) | Out-Null
        }

        [System.Xml.XmlElement]$xamlApplicationPackage = $packagesConfigXml.DocumentElement.SelectSingleNode("//packages/package[@id='Microsoft.Toolkit.Win32.UI.XamlApplication']")

        if ($xamlApplicationPackage)
        {
            $xamlApplicationPackage.ParentNode.RemoveChild($xamlApplicationPackage) | Out-Null
        }

        $packagesConfigXml.Save($packagesConfigFile)
    }
}

# Rename Windows.UI.Xaml to Microsoft.UI.Xaml, except for Windows.UI.Xaml.Interop.TypeKind and TypeName,
# which remain in the WUX namespace tree.

Write-Host "Updating namespaces in source files..."

foreach ($sourceFile in $sourceFilesNeedingUpdates)
{
    [string]$sourceFile = $sourceFile

    Write-Host "    Updating $sourceFile..."

    [string]$fileExtension = [System.IO.Path]::GetExtension($sourceFile)
    [string]$fileContents = [System.IO.File]::ReadAllText($sourceFile)
    $originalFileContents = $fileContents

    $replacements = @(
        @{Original = "Windows\.UI\.Xaml"; Replacement = "Microsoft.UI.Xaml"},
        @{Original = "Windows\.UI\.Colors"; Replacement = "Microsoft.UI.Colors"},
        @{Original = "Microsoft\.Toolkit\.Win32\.UI\.XamlHost\.XamlApplication"; Replacement = "Microsoft.UI.Xaml.Application"},
        @{Original = "Microsoft\.UI\.Xaml\.Interop\.TypeKind"; Replacement = "Windows.UI.Xaml.Interop.TypeKind"},
        @{Original = "Microsoft\.UI\.Xaml\.Interop\.TypeName"; Replacement = "Windows.UI.Xaml.Interop.TypeName"},
        @{Original = "(?:\w+\.)*LaunchActivatedEventArgs"; Replacement = "Microsoft.UI.Xaml.LaunchActivatedEventArgs"},
        @{Original = "IDesktopWindowXamlSourceNative2"; Replacement = "IDesktopWindowXamlSourceNative"}
    )

    foreach ($replacement in $replacements)
    {
        $fileContents = $fileContents -replace $replacement.Original, $replacement.Replacement
    }
    
    if ($fileExtension -eq ".cpp" -or $fileExtension -eq ".h")
    {
        foreach ($replacement in $replacements)
        {
            $fileContents = $fileContents -replace $replacement.Original.Replace("\.", "::"), $replacement.Replacement.Replace(".", "::")
        }
        
        # If Microsoft.UI.Xaml.Interop.h is being included, we may also need Windows.UI.Xaml.Interop.h.
        $fileContents = $fileContents -replace "(#include\s+([`"|<])((?:\w+[\\\/])*)Microsoft\.UI\.Xaml\.Interop\.h([`"|>]))", "`$1$([System.Environment]::NewLine)#include $`2`$3Windows.UI.Xaml.Interop.h`$4"
    }

    if ($sourceFile.ToLower().Contains("pch.h"))
    {
        $fileContents = "$fileContents$([System.Environment]::NewLine)#include <wil/cppwinrt_helpers.h>"
    }

    # We also need to remove some APIs that don't exist in WinAppSDK.
    if ($sourceFile.Contains("App."))
    {
        if ($fileExtension -eq ".h")
        {
            $fileContents = $fileContents -replace "\s*void[^;]*?SuspendingEventArgs[^;]*?;", ""
            $fileContents = $fileContents -replace "\s*void[^;]*?NavigationFailedEventArgs[^;]*?;", ""
            
            $isWinRT = $fileContents -ilike "*winrt*"

            # Add the window reference.
            if ($isWinRT)
            {
                $fileContents = $fileContents -ireplace "((?<classname>\w+)\s*:\s+\k<classname>T<\k<classname>>[^ ]*?( *)[^ ]*?\{(?>\{(?<c>)|[^{}]+|\}(?<-c>))*(?(c)(?!)))\}", "`$1$([Environment]::NewLine)`$2private:$([Environment]::NewLine)`$2    winrt::Microsoft::UI::Xaml::Window m_window{ nullptr };$([Environment]::NewLine)`$2}"
            }
            else # C++/CX
            {
                $fileContents = $fileContents -ireplace "(ref.*class[^{]*?( *)\{(?>\{(?<c>)|[^{}]+|\}(?<-c>))*(?(c)(?!)))\}", "`$1$([Environment]::NewLine)`$2private:$([Environment]::NewLine)`$2    winrt::Microsoft::UI::Xaml::Window m_window{ nullptr };$([Environment]::NewLine)`$2}"
            }
        }
        else
        {
            $isWinRT = $fileContents -ilike "*winrt*"
            
            # Add the window assignment and activation.
            if ($isWinRT)
            {
                $windowCreationRegex = "`$2    m_window = winrt::Microsoft::UI::Xaml::Window();$([System.Environment]::NewLine)`$2    m_window.Activate();$([System.Environment]::NewLine)"
            }
            else # C++/CX
            {
                $windowCreationRegex = "`$2    m_window = ref new Microsoft::UI::Xaml::Window();$([System.Environment]::NewLine)`$2    m_window->Activate();$([System.Environment]::NewLine)"
            }

            # This complex regex matches comments prior to the methods, plus anything in the braces after the method names.
            $fileContents = $fileContents -replace "\s*(?:\/\/.*?\s*)*.*void.*?SuspendingEventArgs[^\{]*\{(?>\{(?<c>)|[^{}]+|\}(?<-c>))*(?(c)(?!))\}", ""
            $fileContents = $fileContents -replace "\s*(?:\/\/.*?\s*)*.*void.*?NavigationFailedEventArgs[^\{]*\{(?>\{(?<c>)|[^{}]+|\}(?<-c>))*(?(c)(?!))\}", ""
            $fileContents = $fileContents -replace "(\s*(?:\/\/.*?\s*)*.*void.*?::OnLaunched[^\{]*?( *))\{(?>\{(?<c>)|[^{}]+|\}(?<-c>))*(?(c)(?!))\}", "`$1`$2{$([System.Environment]::NewLine)$windowCreationRegex`$2}"
        }

        $fileContents = $fileContents -replace "\s*(?:this\.)?Suspending\s*\+=\s*[^;]*;"

        if ($fileExtension -eq ".cpp")
        {
            $fileContents = $fileContents -replace "\s*Suspending\(.*\)\s*;"
        }
    }

    if ($fileContents -ne $originalFileContents)
    {
        [System.IO.File]::WriteAllText($sourceFile, $fileContents, [System.Text.Encoding]::UTF8)
    }
}

Write-Host "Updating namespaces in XAML files..."

foreach ($xamlFile in $xamlFilesNeedingUpdates)
{
    Write-Host "    Updating $xamlFile..."

    [string]$fileContents = [System.IO.File]::ReadAllText($xamlFile)
    $originalFileContents = $fileContents

    # Remove references to the toolkit.
    foreach ($toolkitMatch in ([regex]"\s*xmlns:(\w+)\s*=\s*`"using:Microsoft.Toolkit.Win32.UI.XamlHost`"").Matches($fileContents))
    {
        [System.Text.RegularExpressions.Match]$toolkitMatch = $toolkitMatch
        $toolkitNamespace = $toolkitMatch.Groups[1].Value
        $fileContents = $fileContents -replace $toolkitMatch.Value, ""
        $fileContents = $fileContents -replace "$toolkitNamespace\s*:\s*XamlApplication", "Application"
    }

    $fileContents = $fileContents -replace "(<(?:\w+:)?XamlControlsResources[^>]*?)\s*ControlsResourcesVersion\s*=\s*`"\w+`"([^>]*>)", "`$1`$2"
    $fileContents = $fileContents -replace "(<(?:\w+:)?ColorPicker[^>]*?)\s*Orientation\s*=\s*`"\w+`"([^>]*>)", "`$1`$2"

    if ($fileContents -ne $originalFileContents)
    {
        [System.IO.File]::WriteAllText($xamlFile, $fileContents, [System.Text.Encoding]::UTF8)
    }
}

# Nuget restore the solution files - they need the build tools NuGet for Visual Studio to properly be able to build and deploy them.

Write-Host "Using NuGet to restore the solution files to initialize needed build tools..."

$nugetExePath = "${env:TEMP}\nuget.6.0.0.exe"

if (-not [System.IO.File]::Exists("$nugetExePath"))
{
    Write-Host "Downloading nuget.exe..."
    Invoke-WebRequest https://dist.nuget.org/win-x86-commandline/v6.0.0/nuget.exe -OutFile $nugetExePath
}

foreach ($file in ((Get-ChildItem $ConvertedProjectRoot -Recurse -File -Filter "*.sln")))
{
    Write-Host "    Restoring $($file.FullName)..."
    . $nugetExePath restore $file.FullName | Out-Null
}

Write-Host "Conversion complete."