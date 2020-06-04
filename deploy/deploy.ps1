Param (
    [Parameter(HelpMessage="Deployment storage account resource group")] 
    [string] $DeploymentResourceGroupName = "rg-apimdeploy-local",

    [Parameter(HelpMessage="Deployment storage account name")] 
    [string] $DeploymentStorageName = "apimdeploylocal",

    [Parameter(HelpMessage="Deployment container")] 
    [string] $DeploymentContainer = "localcustomdomain",

    [Parameter(HelpMessage="Deployment target resource group")] 
    [string] $ResourceGroupName = "rg-apim2-local",

    [Parameter(HelpMessage="Deployment target resource group location")] 
    [string] $Location = "North Europe",

    [Parameter(HelpMessage="API Management Name")] 
    [string] $APIMName = "contosoapim2-local",

    [string] $Template = "azuredeploy.json",
    [string] $TemplateParameters = "$PSScriptRoot\azuredeploy.parameters.json"
)

$ErrorActionPreference = "Stop"

$date = (Get-Date).ToString("yyyy-MM-dd-HH-mm-ss")
$deploymentName = "Local-$date"

if ([string]::IsNullOrEmpty($env:RELEASE_DEFINITIONNAME))
{
    Write-Host (@"
Not executing inside Azure DevOps Release Management.
Make sure you have done "Login-AzAccount" and
"Select-AzSubscription -SubscriptionName name"
so that script continues to work correctly for you.
"@)
}
else
{
    $deploymentName = $env:RELEASE_RELEASENAME
}

# Deployment helper storage account
if ($null -eq (Get-AzResourceGroup -Name $DeploymentResourceGroupName -Location $Location -ErrorAction SilentlyContinue))
{
    Write-Warning "Resource group '$DeploymentResourceGroupName' doesn't exist and it will be created."
    New-AzResourceGroup -Name $DeploymentResourceGroupName -Location $Location -Verbose
    New-AzStorageAccount `
        -ResourceGroupName $DeploymentResourceGroupName `
        -Name $DeploymentStorageName `
        -Location $Location `
        -SkuName Standard_LRS `
        -EnableHttpsTrafficOnly
}

Set-AzCurrentStorageAccount -ResourceGroupName $DeploymentResourceGroupName -Name $DeploymentStorageName

if ($null -eq (Get-AzStorageContainer -Name $DeploymentContainer -ErrorAction SilentlyContinue))
{
    Write-Warning "Deployment storage container '$DeploymentContainer' doesn't exist and it will be created."
    New-AzStorageContainer -Name $DeploymentContainer
}

$folder = "$PSScriptRoot\"
Get-ChildItem -File -Recurse $folder -Exclude *.ps1 `
    | ForEach-Object  { 
        $name = $_.FullName.Replace($folder,"")
        $properties = @{"ContentType" = "application/json"}

        Write-Host "Deploying file: $name"
        Set-AzStorageBlobContent -File $_.FullName -Blob $name -Container $DeploymentContainer -Properties $properties -Force
    }

$templateUrl = (Get-AzStorageContainer -Container $DeploymentContainer).CloudBlobContainer.StorageUri.PrimaryUri.AbsoluteUri + "/"
$templateToken = New-AzStorageContainerSASToken -Name $DeploymentContainer -Permission r -ExpiryTime (Get-Date).AddMinutes(30.0)

# Target deployment resource group
if ($null -eq (Get-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction SilentlyContinue))
{
    Write-Warning "Resource group '$ResourceGroupName' doesn't exist and it will be created."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Verbose
}

# Additional parameters that we pass to the template deployment
$additionalParameters = New-Object -TypeName hashtable
$additionalParameters['apimName'] = $APIMName
$additionalParameters['templateUrl'] = $templateUrl
$additionalParameters['templateToken'] = ConvertTo-SecureString -String $templateToken -AsPlainText

$result = New-AzResourceGroupDeployment `
    -DeploymentName $deploymentName `
    -ResourceGroupName $ResourceGroupName `
    -TemplateUri ($templateUrl + $Template + $templateToken) `
    -TemplateParameterFile $TemplateParameters `
    @additionalParameters `
    -Mode Complete -Force `
    -Verbose

if ($null -eq $result.Outputs.apimGateway)
{
    Throw "Template deployment didn't return web app information correctly and therefore deployment is cancelled."
}

$result | Select-Object -ExcludeProperty TemplateLinkString

$apimGateway = $result.Outputs.apimGateway.value

# Publish variable to the Azure DevOps agents so that they
# can be used in follow-up tasks such as application deployment
Write-Host "##vso[task.setvariable variable=Custom.APIMGateway;]$apimGateway"
