#Set-PSBreakpoint -Variable Message
$StartTime = Get-Date

<#
#https://github.com/PowerShell/PowerShell/issues/8000
$LogFile = (($Global:MyInvocation.MyCommand.Definition | Split-Path -Parent) + '\Logs\' + (($Global:MyInvocation.MyCommand.Definition | Split-Path -Leaf) -replace "\..+",'.log'))
Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -SupportEvent -Action { Write-Information ((Get-Date) - $StartTime | % { 'Script closed after {0} hours {1} minute {2} seconds {3} milliseconds' -f $_.Days,$_.Minutes,$_.Seconds,$_.Milliseconds }) | Out-File -LiteralPath $LogFile -Append -Force }
#>

function Write-Log 
{
    [CmdletBinding()]
    param
    (
        [String]$Message,

        [String]$Stream,
        
        #Unless specified, default logs are created in the logs folder of the script location
        [String]$LogFile = (($Global:MyInvocation.MyCommand.Definition | Split-Path -Parent) + '\Logs\' + (($Global:MyInvocation.MyCommand.Definition | Split-Path -Leaf) -replace "\..+",'.log')),    
               
        [Object]$Stack
    )
    begin
    {
        #If the log file does not exist, create it
        if(-not (($MyInvocation.CommandOrigin -eq "Runspace") -or (Test-Path -LiteralPath $LogFile -ErrorAction Stop)))
        {
            [Void](New-Item -Path $logFile -ItemType File -Force -ErrorAction Stop)
        }
        #TODO: find out the best way to obtain TargetUser and TargetMachine from the script,
        # due to lack of consistency, the variable names are different. Refactoring is likely 
        # required to capture this information.
    }
    process
    {
        if(-not ($MyInvocation.CommandOrigin -eq "Runspace"))
        {
            $DateTime = (Get-Date -Format 'yy-MM-dd HH:mm:ss')
        
            #Any pre-processing we need to do on the output in preperation for logging
            switch($Stream)
            {
                'Debug'       {}
                'Default'     {$Stream = "Console"}
                'Error'       {}
                'Host'        {}
                'Information' {}
                'Output'      {}
                'Verbose'     {}
                'Warning'     {}
                #Format commands
                'List'        {$Stream = "Console"}
                'Table'       {$Stream = "Console"}
                'Wide'        {$Stream = "Console"}
            }

            if([String]::IsNullOrEmpty($Message))
            {
                $Message = 'Command produced no output'
            }

            #CSV or Log format for CMTrace? - Or both? - Currently pipe delimitered.
            #(Get-Culture).TextInfo.ListSeparator for the default delimiter, ',' in en-GB (2057)
            #tab characters ([char]9) is stripped out by cmtrace
            $Output = @(
                "$DateTime"
                "$env:COMPUTERNAME\$env:USERNAME"
                "[$((Get-Culture).TextInfo.ToTitleCase($Stream))]"
                "Message: '$Message'"
                "Command: '$($Stack.Position.Text)'"
                "Position: Line:$($Stack.Position.StartLineNumber) Col:$($Stack.Position.StartColumnNumber) to Line:$($Stack.Position.EndLineNumber) Col:$($Stack.Position.EndColumnNumber)"
                "TotalTime: $([String]((Get-Date) - $StartTime))"
                "Host: $($Host.Name) ($([string]$Host.Version))"
            ) 

            Microsoft.PowerShell.Utility\Write-Output ($Output -join ' | ' -replace "`r`n", " ") | Out-File -LiteralPath $LogFile -Append -Force
        }
    }
    end
    {
          
    } 
}

function Out-Proxy 
{
    # Function that intercepts the output streams, calls Write-Log and then continues with the default behaviour
    # of the output stream.
    # https://get-powershellblog.blogspot.com/2017/04/out-default-secrets-revealed.html
    # https://github.com/PowerShell/PowerShell/tree/f76b2fcbafb92c784aa8a200e412353f7e864824/src/Microsoft.PowerShell.Utility.Activities/Generated
    [CmdletBinding()]
    [Alias('Write-Verbose','Write-Warning','Write-Information','Write-Error','Write-Debug','Write-Output','Write-Host','Out-Default','Out-Host','Format-Table','Format-List','Format-Wide','Read-Host')]
    Param()
    DynamicParam 
    {
        #These parameters are defined by [CmdletBinding()], regenerating them causes conflicts.
        $ExcludedParameters = "Verbose,Debug,ErrorAction,WarningAction,InformationAction,ErrorVariable,WarningVariable,InformationVariable,OutVariable,OutBuffer,PipelineVariable" -split ","
        # Create the dictionary that this scriptblock will return:
        [void]($RuntimeDefinedParameterDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary)
        # Get dynamic params that real Cmdlet would have:
        $Parameters = (Get-Command -CommandType Cmdlet -Name $MyInvocation.InvocationName -ArgumentList $PSBoundParameters).Parameters
        foreach ($Parameter in $Parameters.GetEnumerator() | ? {$_.Key -notin $ExcludedParameters}) 
        {
            $RuntimeDefinedParameter = New-Object System.Management.Automation.RuntimeDefinedParameter($Parameter.Key, $Parameter.Value.ParameterType, $Parameter.Value.Attributes)
            $RuntimeDefinedParameterDictionary.Add($Parameter.Key, $RuntimeDefinedParameter)
        }
        # Return the dynamic parameters
        return $RuntimeDefinedParameterDictionary
    }
    begin 
    {
        try 
        {
            $OutBuffer = $null
            $Alias = $MyInvocation.InvocationName
            if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer))
            {
                $PSBoundParameters['OutBuffer'] = -1
            }
            $WrappedCmd = $ExecutionContext.InvokeCommand.GetCommand("$((Get-Command $Alias -CommandType Cmdlet).Source)\$Alias", [System.Management.Automation.CommandTypes]::Cmdlet)
            $ScriptCmd = {& $WrappedCmd @PSBoundParameters}
            $SteppablePipeline = $ScriptCmd.GetSteppablePipeline($MyInvocation.CommandOrigin)
            $SteppablePipeline.Begin($PSCmdlet)
        } 
        catch 
        {

        }
    }

    process 
    {
        try 
        {
            #To map the different parameters to variables so that we can log conistently
            Switch -Regex($PSBoundParameters.GetEnumerator())
            {
               'InputObject|Message|Object|MessageData' { [String]$Message = $_.Value }
            }
            
            $StackNumber = -1

            #Pass the information to our custom logging function. 
            [void](Write-Log -Message $Message -Stream ($Alias -replace ".+-") -Stack ((Get-PSCallStack)[$StackNumber]))
            $SteppablePipeline.Process($_)
        } 
        catch 
        {
            $_
        }
    }
    end
    {
        try
        {
            $steppablePipeline.End()
        }
        catch
        {

        }
    }
}

Export-ModuleMember -Function Out-Proxy
Export-ModuleMember -Function Write-Log
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Format-List 
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Format-Table
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Format-Wide
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Write-Error
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Write-Information
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Write-Verbose
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Write-Warning
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Write-Debug
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Write-Output
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Write-Host
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Out-Default
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Out-Host
New-Alias -Value Out-Proxy -Description "AutoLog Proxy" -Force -Scope 1 -Name Read-Host

#Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -SupportEvent -Action { Write-Information ((Get-Date) - $StartTime | % { 'Script closed after {0} hours {1} minute {2} seconds {3} milliseconds' -f $_.Days,$_.Minutes,$_.Seconds,$_.Milliseconds }) | Out-File -LiteralPath $LogFile -Append -Force }
#$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {Write-Verbose ((Get-Date) - $StartTime | % { 'Module was loaded for {0:n0} hours {1} minutes {2} seconds {3} milliseconds' -f $_.TotalHours,$_.Minutes,$_.Seconds,$_.Milliseconds }) }
Write-Log -Message "Module imported" -Stream Verbose -Stack (Get-PSCallStack)[-1]

