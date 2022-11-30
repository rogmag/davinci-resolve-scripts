<#

	To execute this file from Tools > External Tools in Visual Studio set the following fields:

	    Title: Deploy to DaVinci Resolve
	  Command: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
	Arguments: -ExecutionPolicy Unrestricted -File "$(SolutionDir)\Deploy.ps1" -ProjectPath "$(SolutionDir)"

#>

[CmdletBinding()]
param
(
	[parameter(Mandatory = $true)]
	[string] $ProjectPath
)

$resolveAppData = "$env:APPDATA/Blackmagic Design/DaVinci Resolve"							# Current User (Windows)
#$resolveAppData = "$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve"	# Current User (macOS)
#$resolveAppData = "$HOME/.local/share/DaVinciResolve"										# Current User (Linux)
$resolveFusion = "$resolveAppData/Support/Fusion"

if (Test-Path -Path $resolveAppData)
{
	if (!(Test-Path -Path $resolveFusion))
	{
		# No "Support" folder means the target is macOS or Linux and we need another path
		$resolveFusion = "$resolveAppData/Fusion"
	}
}
else
{
	throw "DaVinci Resolve not found"
}

function Deploy-Files
{
	[CmdletBinding()]
	param
	(
		[parameter(Mandatory = $true)]
		[string] $Source,

		[parameter(Mandatory = $true)]
		[string] $Destination
	)

	Write-Host("Purging ""$Destination*""...")
	Remove-Item -Path $Destination* -Recurse -Force -ErrorAction:SilentlyContinue

	Write-Host("Copying from ""$Source"" to ""$Destination""...")
	Copy-Item -Path $Source -Destination $Destination -Recurse -Container -Force -ErrorAction:Stop
	
	Write-Host("")
}

Deploy-Files -Source ("{0}Modules/Lua/*" -f $ProjectPath) -Destination "$resolveFusion/Modules/Lua/"
Deploy-Files -Source ("{0}Scripts/*" -f $ProjectPath) -Destination "$resolveFusion/Scripts/"
