function RemoveAndCleanEmptyNodes([System.Xml.XmlNode]$node)
{
    $parentNode = $node.ParentNode
    $parentNode.RemoveChild($node) | Out-Null
    $node = $parentNode

    while (-not $node.HasChildNodes)
    {
        $parentNode = $node.ParentNode
        $parentNode.RemoveChild($node) | Out-Null
        $node = $parentNode
    }
}

function CreateOrUpdateProperty([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$propertyName, [string]$newPropertyContents)
{
    $propertyUpdated = $false

    foreach ($propertyElement in $xmlDocument.DocumentElement.SelectNodes("//x:PropertyGroup/x:$propertyName", $namespaceManager))
    {
        [System.Xml.XmlElement]$propertyElement = $propertyElement

        $propertyElement.RemoveAll()
        $propertyElement.AppendChild($xmlDocument.CreateTextNode($newPropertyContents)) | Out-Null

        $propertyUpdated = $true
    }

    if (-not $propertyUpdated)
    {
        $propertyGroupElement = $xmlDocument.DocumentElement.SelectSingleNode("//x:PropertyGroup[1]", $namespaceManager)

        if ($propertyGroupElement)
        {
            [System.Xml.XmlElement]$newPropertyElement = $xmlDocument.CreateElement([string]::Empty, $propertyName, $xmlDocument.DocumentElement.NamespaceURI)
            $newPropertyElement.AppendChild($xmlDocument.CreateTextNode($newPropertyContents)) | Out-Null
            $propertyGroupElement.AppendChild($newPropertyElement) | Out-Null
        }
    }
}

function RemoveProperty([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$propertyName)
{
    foreach ($propertyElement in $xmlDocument.DocumentElement.SelectNodes("//x:PropertyGroup/x:$propertyName", $namespaceManager))
    {
        [System.Xml.XmlElement]$propertyElement = $propertyElement
        RemoveAndCleanEmptyNodes $propertyElement
    }
}

function CreateItem([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$itemName, [string]$includeText, [string]$condition)
{
    # if the item already exists, don't update anything.
    foreach ($itemElement in $xmlDocument.DocumentElement.SelectNodes("//x:ItemGroup/x:$itemName[@Include='$includeText']", $namespaceManager))
    {
        return
    }

    [System.Xml.XmlElement]$item = $xmlDocument.CreateElement([string]::Empty, $itemName, $xmlDocument.DocumentElement.NamespaceURI)
    $item.SetAttribute("Include", $includeText)

    if ($condition)
    {
        $item.SetAttribute("Condition", $condition)
    }

    [System.Xml.XmlElement]$newItemGroup = $xmlDocument.CreateElement([string]::Empty, "ItemGroup", $xmlDocument.DocumentElement.NamespaceURI)
    $newItemGroup.AppendChild($item) | Out-Null

    # We'll append the new item group after the last item group.

    [System.Xml.XmlElement]$lastItemGroupElement = $xmlDocument.DocumentElement.SelectSingleNode("//x:ItemGroup[last()]", $namespaceManager)
    $xmlDocument.DocumentElement.InsertAfter($newItemGroup, $lastItemGroupElement) | Out-Null
}

function UpdateItem([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$itemName, [string]$includeText, [string]$newIncludeText)
{
    foreach ($itemElement in $xmlDocument.DocumentElement.SelectNodes("//x:ItemGroup/x:$itemName[@Include='$includeText']", $namespaceManager))
    {
        [System.Xml.XmlElement]$itemElement = $itemElement
        $itemElement.SetAttribute("Include", $newIncludeText)
    }
}

function RemoveItem([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$itemName, [string]$includeText)
{
    foreach ($itemElement in $xmlDocument.DocumentElement.SelectNodes("//x:ItemGroup/x:$itemName[@Include='$includeText']", $namespaceManager))
    {
        RemoveAndCleanEmptyNodes $itemElement
    }
}

function RemoveItemDefinitionGroupProperty([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$itemDefinitionGroupName, [string]$itemDefinitionGroupProperty)
{
    foreach ($propertyElement in $xmlDocument.DocumentElement.SelectNodes("//x:ItemDefinitionGroup/x:$itemDefinitionGroupName/x:$itemDefinitionGroupProperty", $namespaceManager))
    {
        RemoveAndCleanEmptyNodes $propertyElement
    }
}

function RemoveFromItemDefinitionGroupProperty([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$itemDefinitionGroupName, [string]$itemDefinitionGroupProperty, [string]$itemDefinitionGroupContents)
{
    foreach ($propertyElement in $xmlDocument.DocumentElement.SelectNodes("//x:ItemDefinitionGroup/x:$itemDefinitionGroupName/x:$itemDefinitionGroupProperty", $namespaceManager))
    {
        [System.Xml.XmlElement]$propertyElement = $propertyElement
        $propertyElement.InnerText = $propertyElement.InnerText -replace $itemDefinitionGroupContents, ""

        # Also remove any now-orphaned semicolons or spaces.
        $originalInnerText = ""

        while ($originalInnerText -ne $propertyElement.InnerText)
        {
            $originalInnerText = $propertyElement.InnerText
            $propertyElement.InnerText = $propertyElement.InnerText -replace "(?<!([^;]|\s)+)(;|\s)+", ""
            $propertyElement.InnerText = $propertyElement.InnerText -replace "(;|\s)+(?!([^;]|\s)+)", ""
            $propertyElement.InnerText = $propertyElement.InnerText.Trim()
        }

        # If this item definition group is now just a no-op, remove it.
        if ($propertyElement.InnerText -ieq "%($itemDefinitionGroupProperty)")
        {
            RemoveAndCleanEmptyNodes $propertyElement
        }
    }
}

function CreateNugetImport([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$importPath, [string]$importRelativeToFilename)
{
    # If the item already exists, don't add anything.
    foreach ($importElement in $xmlDocument.DocumentElement.SelectNodes("//x:Import[@Project='$importPath']", $namespaceManager))
    {
        return
    }

    [System.Xml.XmlElement]$import = $xmlDocument.CreateElement([string]::Empty, "Import", $xmlDocument.DocumentElement.NamespaceURI)
    $import.SetAttribute("Project", $importPath)
    $import.SetAttribute("Condition", "Exists('$importPath')")

    # If the import we want to insert this relative to exists, we'll insert it relative to that.
    $importRelativeTo = $xmlDocument.SelectSingleNode("//x:Import[contains(@Project, '$importRelativeToFilename')]", $namespaceManager)

    if ($importRelativeTo)
    {
        $importRelativeTo.ParentNode.InsertAfter($import, $importRelativeTo) | Out-Null
    }
    else
    {
        # Otherwise, we'll put .props files at the top and .targets files within the ExtensionTargets import group.
        if ([System.IO.Path]::GetExtension($importRelativeToFilename) -eq ".props")
        {
            $xmlDocument.DocumentElement.PrependChild($import) | Out-Null
        }
        else
        {
            [System.Xml.XmlElement]$extensionTargetsGroup = $xmlDocument.SelectSingleNode("//x:ImportGroup[@Label='ExtensionTargets']", $namespaceManager)

            if (-not $extensionTargetsGroup)
            {
                [System.Xml.XmlElement]$extensionTargetsGroup = $xmlDocument.CreateElement([string]::Empty, "ImportGroup", $xmlDocument.DocumentElement.NamespaceURI)
                $extensionTargetsGroup.SetAttribute("Label", "ExtensionTargets")

                [System.Xml.XmlElement]$firstTarget = $xmlDocument.SelectSingleNode("//x:Target[1]", $namespaceManager)

                if ($firstTarget)
                {
                    $firstTarget.ParentNode.InsertBefore($extensionTargetsGroup, $firstTarget) | Out-Null
                }
                else
                {
                    $xmlDocument.AppendChild($extensionTargetsGroup) | Out-Null
                }
            }

            $extensionTargetsGroup.AppendChild($import) | Out-Null
        }
    }

    # We also need to add an entry to the nuget import checker target.
    [System.Xml.XmlElement]$error = $xmlDocument.CreateElement([string]::Empty, "Error", $xmlDocument.DocumentElement.NamespaceURI)
    $error.SetAttribute("Condition", "!Exists('$importPath')")
    $error.SetAttribute("Text", "`$([System.String]::Format('`$(ErrorText)', '$importPath'))")
    
    # We'll first check whether the nuget import checker target even exists.
    $ensureNugetImportsTarget = $xmlDocument.DocumentElement.SelectSingleNode("//x:Target[@Name='EnsureNuGetPackageBuildImports']", $namespaceManager)

    if ($ensureNugetImportsTarget)
    {
        # If it does, we'll insert this at the end.
        $ensureNugetImportsTarget.AppendChild($error) | Out-Null
    }
    else
    {
        # If it doesn't, we'll create it and add this to it.
        [System.Xml.XmlElement]$ensureNugetImportsTarget = $xmlDocument.CreateElement([string]::Empty, "Target", $xmlDocument.DocumentElement.NamespaceURI)
        $ensureNugetImportsTarget.SetAttribute("Name", "EnsureNuGetPackageBuildImports")
        $ensureNugetImportsTarget.SetAttribute("BeforeTargets", "PrepareForBuild")

        $xmlDocument.DocumentElement.AppendChild($ensureNugetImportsTarget) | Out-Null

        [System.Xml.XmlElement]$errorTextPropertyGroup = $xmlDocument.CreateElement([string]::Empty, "PropertyGroup", $xmlDocument.DocumentElement.NamespaceURI)
        [System.Xml.XmlElement]$errorTextProperty = $xmlDocument.CreateElement([string]::Empty, "ErrorText", $xmlDocument.DocumentElement.NamespaceURI)
        [System.Xml.XmlText]$errorText = $xmlDocument.CreateTextNode("This project references NuGet package(s) that are missing on this computer. Use NuGet Package Restore to download them.  For more information, see http://go.microsoft.com/fwlink/?LinkID=322105. The missing file is {0}.")
        $errorTextProperty.AppendChild($errorText) | Out-Null
        $errorTextPropertyGroup.AppendChild($errorTextProperty) | Out-Null
        $ensureNugetImportsTarget.AppendChild($errorTextPropertyGroup) | Out-Null

        # Now we can add the error.
        $ensureNugetImportsTarget.AppendChild($error) | Out-Null
    }
}

function RemoveNugetImport([System.Xml.XmlDocument]$xmlDocument, [System.Xml.XmlNamespaceManager]$namespaceManager, [string]$importPathSubstring)
{
    foreach ($importElement in $xmlDocument.DocumentElement.SelectNodes("//x:Import[contains(@Project, '$importPathSubstring')]", $namespaceManager))
    {
        RemoveAndCleanEmptyNodes $importElement
    }

    foreach ($errorElement in $xmlDocument.DocumentElement.SelectNodes("//x:Target[@Name='EnsureNuGetPackageBuildImports']/x:Error[contains(@Text, '$importPathSubstring')]", $namespaceManager))
    {
        RemoveAndCleanEmptyNodes $errorElement
    }
}